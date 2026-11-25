#!/bin/bash
# Test of the GOB lab of kathara/: n1 to n5 on the GOB UML kernel and the
# image kathara-uml/gob, h1 and h2 containers. After a ping from h1 to h2,
# each GOB node must have folded its metric (10, 20, 30, 40, 50) into the
# GOB, and recorded the GOB that it received from the nodes before it, as
# tests/scripts/gob-demo/gob-demo-5node-recv-auto.sh expects. The GOB
# program also writes a line per packet with bpf_printk.
#
# It needs what build.sh builds: the kernel in out/kernel, the image and
# lab/shared/ioam6_gob_recv.o. It uses a copy of lab in a temporary
# directory, so a lab already running is not touched. Run it where Kathara
# and the image are: `build.sh test`, or `bash tests/check-gob.sh`.
#
# Prints one OK/FAIL line per check and exits non-zero if one failed.

# shellcheck source=lib.sh source-path=SCRIPTDIR/../kathara-uml-lab/tests
. "$(dirname "$0")/../kathara-uml-lab/tests/lib.sh"

HERE=$(cd "$(dirname "$0")" && pwd)
IMAGE=kathara-uml/gob
GOB_RELEASE=6.18.0-rc1

# A copy of the GOB lab, whose link to the kernel points back to out/kernel.
setup_lab()
{
	LAB=$(mktemp -d)
	trap 'kathara lclean -d "$LAB" >/dev/null 2>&1; rm -rf "$LAB"' EXIT
	cp -r "$HERE/../lab/." "$LAB"
	rm -f "$LAB/kernel"
	ln -s "$HERE/../out/kernel" "$LAB/kernel"
}

# A command in a device of the lab, through a shell, without the \r of the
# terminal.
in_dev()
{
	kathara exec -d "$LAB" "$1" "bash -c '$2'" 2>&1 | tr -d '\r'
}

# yes once gob-node.sh said that the node is ready, no if it failed or it
# took more than 120 s.
node_ready()
{
	local node=$1 i

	for ((i = 0; i < 120; i++)); do
		case "$(in_dev "$node" "tail -1 /var/log/gob-node.log 2>/dev/null")" in
		*ready*)
			echo yes
			return
			;;
		*failed*)
			echo no
			return
			;;
		esac
		sleep 1
	done
	echo no
}

# The GOB that node nK recorded in its slot of gob_recv, slot K, as
# "min max sum count pkts". bpftool -j gives the bytes under key and value,
# and the fields, decoded with the BTF of the map, under formatted.
gob_received()
{
	local node=$1

	in_dev "$node" "bpftool -j map lookup pinned /sys/fs/bpf/tc/globals/gob_recv key ${node#n} 0 0 0" |
		python3 -c 'import json, sys; v = json.load(sys.stdin)["formatted"]["value"]; print(v["min"], v["max"], v["sum"], v["count"], v["pkts"])'
}

# Checks the GOB that a node received, and the packets it processed.
check_received()
{
	local node=$1 want=$2 min max sum count pkts

	read -r min max sum count pkts <<< "$(gob_received "$node")"
	check "$node received the GOB: min max sum count" "$min $max $sum $count" "$want"
	check "$node processed the 3 packets" "$pkts" 3
}

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "no image $IMAGE: build.sh image" >&2
	exit 1
fi
if [ ! -f "$HERE/../out/kernel/linux" ] || [ ! -f "$HERE/../lab/shared/ioam6_gob_recv.o" ]; then
	echo "no kernel or no GOB program: build.sh" >&2
	exit 1
fi
if [ -n "$(docker ps -q --filter label=app=kathara)" ]; then
	echo "a Kathara lab is running: stop it first" >&2
	exit 1
fi

setup_lab
kathara lstart --noterminals -d "$LAB" >/dev/null 2>&1
check "lstart" "$?" 0
for node in n1 n2 n3 n4 n5; do
	check "$node is a GOB node" "$(node_ready "$node")" yes
	check "$node runs on the GOB kernel" "$(in_dev "$node" "uname -r")" "$GOB_RELEASE"
done

pinged=$(kathara exec -d "$LAB" h1 "ping -6 -c 3 -i 0.3 -W 2 -I fdcc::1 fdcc::2" | grep -o '[0-9]* received' | cut -d' ' -f1)
check "pings from h1 to h2 through the GOB nodes" "$pinged" 3

check_received n2 "10 10 10 1"
check_received n3 "10 20 30 2"
check_received n4 "10 30 60 3"
check_received n5 "10 40 100 4"
check "bpf_printk of the GOB program of n5 in the trace buffer" \
	"$(in_dev n5 "grep -c \"ioam6_gob_recv node=5: recv count=4 metric=50\" /sys/kernel/tracing/trace")" 3

finish GOB
