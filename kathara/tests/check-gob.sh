#!/bin/bash
# Test of the GOB lab of kathara/: n1 to n5 on the image of the GOB nodes
# and on the GOB UML kernel in it, h1 and h2 containers. After a ping from
# h1 to h2, each GOB node must have folded its metric (10, 20, 30, 40, 50)
# into the GOB, and recorded the GOB that it received from the nodes before
# it, as tests/scripts/gob-demo/gob-demo-5node-recv-auto.sh expects. The
# GOB program also writes a line per packet with bpf_printk.
#
# The lab runs twice: as it is, every GOB node on the kernel of its image,
# then, if build.sh built the kernel in out/kernel, with n3 on that kernel
# through the kernel option, which takes the place of the kernel of the
# image. It needs the image that lab/lab.conf names and
# lab/shared/ioam6_gob_recv.o, and uses copies of lab in temporary
# directories, so a lab already running is not touched. Run it where
# Kathara and the image are: `build.sh test`, or `bash tests/check-gob.sh`.
#
# Prints one OK/FAIL line per check and exits non-zero if one failed.

# shellcheck source=lib.sh source-path=SCRIPTDIR/../kathara-uml-lab/tests
. "$(dirname "$0")/../kathara-uml-lab/tests/lib.sh"

HERE=$(cd "$(dirname "$0")" && pwd)
# The image of the GOB nodes, as lab.conf names it, and the release of the
# kernel in it, which starts its tag.
IMAGE=$(sed -n 's/^n1\[image\]="\(.*\)"$/\1/p' "$HERE/../lab/lab.conf")
TAG=${IMAGE##*:}
GOB_RELEASE=${TAG%-*}
IMAGE_KERNEL=/usr/lib/kathara-uml/linux
KERNEL=$HERE/../out/kernel/linux
LABS=()

# A copy of the GOB lab in LAB, with n3 on the kernel given, if any. It is
# not printed for a $(...): LABS, which clean_labs reads, must grow in this
# shell.
setup_lab()
{
	local kernel=$1

	LAB=$(mktemp -d)
	LABS+=("$LAB")
	cp -r "$HERE/../lab/." "$LAB"
	if [ -n "$kernel" ]; then
		echo "n3[kernel]=\"$kernel\"" >> "$LAB/lab.conf"
	fi
}

# shellcheck disable=SC2317 # called from the EXIT trap
clean_labs()
{
	local lab

	for lab in "${LABS[@]}"; do
		kathara lclean -d "$lab" >/dev/null 2>&1
		rm -rf "$lab"
	done
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

# Where the container of a node takes its kernel from: image if it runs on
# the kernel of its image (KATHARA_UML_KERNEL), option if the kernel option
# is mounted, else none.
kernel_from()
{
	local node=$1 container

	container=$(docker ps -q --filter label=name="$node" | head -1)
	if docker inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' "$container" |
		grep -qx /kathara-uml-kernel; then
		echo option
	elif docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container" |
		grep -qx "KATHARA_UML_KERNEL=$IMAGE_KERNEL"; then
		echo image
	else
		echo none
	fi
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
	local what=$1 node=$2 want=$3 min max sum count pkts

	read -r min max sum count pkts <<< "$(gob_received "$node")"
	check "$what: $node received the GOB: min max sum count" "$min $max $sum $count" "$want"
	check "$what: $node processed the 3 packets" "$pkts" 3
}

# The lab in LAB: lstart, the kernel of each GOB node, where it comes from
# (want_n3 for n3, image for the others), a ping from h1 to h2, the GOB that
# each node received and the bpf_printk lines of n5.
check_lab()
{
	local what=$1 want_n3=$2 node want pinged

	kathara lstart --noterminals -d "$LAB" >/dev/null 2>&1
	check "$what: lstart" "$?" 0
	for node in n1 n2 n3 n4 n5; do
		want=image
		if [ "$node" = n3 ]; then
			want=$want_n3
		fi
		check "$what: $node runs on the kernel of the $want" "$(kernel_from "$node")" "$want"
		check "$what: $node is a GOB node" "$(node_ready "$node")" yes
		check "$what: $node runs on the GOB kernel" "$(in_dev "$node" "uname -r")" "$GOB_RELEASE"
	done

	pinged=$(kathara exec -d "$LAB" h1 "ping -6 -c 3 -i 0.3 -W 2 -I fdcc::1 fdcc::2" |
		grep -o '[0-9]* received' | cut -d' ' -f1)
	check "$what: pings from h1 to h2 through the GOB nodes" "$pinged" 3

	check_received "$what" n2 "10 10 10 1"
	check_received "$what" n3 "10 20 30 2"
	check_received "$what" n4 "10 30 60 3"
	check_received "$what" n5 "10 40 100 4"
	check "$what: bpf_printk of the GOB program of n5 in the trace buffer" \
		"$(in_dev n5 "grep -c \"ioam6_gob_recv node=5: recv count=4 metric=50\" /sys/kernel/tracing/trace")" 3
	kathara lclean -d "$LAB" >/dev/null 2>&1
}

if [ -z "$IMAGE" ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "no image ${IMAGE:-in lab/lab.conf}: build.sh, or let Kathara pull it" >&2
	exit 1
fi
if [ ! -f "$HERE/../lab/shared/ioam6_gob_recv.o" ]; then
	echo "no GOB program: build.sh program" >&2
	exit 1
fi
if [ -n "$(docker ps -q --filter label=app=kathara)" ]; then
	echo "a Kathara lab is running: stop it first" >&2
	exit 1
fi
trap clean_labs EXIT

setup_lab
check_lab "kernel of the image" image
if [ -f "$KERNEL" ]; then
	setup_lab "$(realpath "$KERNEL")"
	check_lab "n3 on the kernel option" option
else
	echo "no kernel in out/kernel: the run with n3 on the kernel option is skipped"
fi

finish GOB
