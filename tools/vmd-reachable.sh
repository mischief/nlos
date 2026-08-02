#!/bin/sh
# vmd-reachable.sh [ELF] -- is an idle guest actually on the network?
#
# Run on the OpenBSD host, not in the build. It answers the one thing
# the test suite cannot: whether this machine is reachable when nothing
# inside it is doing anything.
#
# That was the whole justification for task/ip.lua. Before it, the stack
# only existed while some proc sat inside pump(), so a guest was
# pingable exactly as long as something was driving it and fell off the
# network the instant that returned. Asserting the fix from inside the
# guest is impossible -- it needs a stranger to knock -- and qemu's
# slirp will not carry inbound ICMP, so it needs vmd.
#
# Nothing is injected and nothing is typed. The guest boots, kernel.c
# starts eth, the ip stack and the dhcp client, and by the time this
# pings it the machine has configured itself and is answering ARP and
# ICMP with every one of its procs asleep.
#
# The idle cpu figure is the second half of the claim: a stack that
# polled its device would show a pegged vcpu here. What makes it zero is
# the interrupt path -- the device wakes the eth task, which wakes the
# stack, and in between the guest halts.

set -e

elf=${1:-luaos.elf}
name=${VMNAME:-reachable}

if [ ! -f "$elf" ]; then
	echo "$0: no kernel at $elf" >&2
	exit 1
fi

vmctl stop -f "$name" >/dev/null 2>&1 || true

# -L gives the guest a local interface with vmd's own dhcp server on the
# other end, so the address it configures itself with is one we can work
# out: the host takes 100.64.N.2 and the guest 100.64.N.3.
vmctl start -L -m 256M -b "$elf" "$name"
sleep 6

iface=$(ifconfig | grep -B4 "description: vm.*-$name" | grep -o '^tap[0-9]*' | head -1)
if [ -z "$iface" ]; then
	iface=$(ifconfig tap | grep -o '^tap[0-9]*' | tail -1)
fi

hostaddr=$(ifconfig "$iface" | awk '/inet /{print $2}')
guest=$(echo "$hostaddr" | awk -F. '{print $1"."$2"."$3"."$4+1}')

echo "# host $hostaddr on $iface, guest should be $guest"
echo

echo "# ping an idle guest -- nothing inside it is running"
ping -c 4 -w 8 "$guest" || true
echo

echo "# and it answered arp, or the ping could not have gone out"
arp -an | grep "$guest" || echo "(no entry -- it did not answer)"
echo

pid=$(vmctl status "$name" | awk 'NR==2{print $2}')
echo "# cpu while idle: a polling stack would peg this"
ps -o pcpu,time,command -p "$pid" | tail -1
sleep 5
ps -o pcpu,time,command -p "$pid" | tail -1

vmctl stop -f "$name" >/dev/null 2>&1 || true
