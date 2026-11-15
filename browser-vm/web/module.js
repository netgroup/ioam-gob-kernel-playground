// QEMU arguments for the GOB browser VM. Loaded by index.html before the
// emscripten module starts.
const params = new URLSearchParams(location.search);
let append = 'console=ttyS0,115200n8 root=/dev/vda rw rootwait init=/sbin/gob-init loglevel=4';
if (params.get('test') === '1')
    append += ' gobtest=1 gobtest_clang=1';
// The guest sets its console size from this (index.html computes it).
if (window.gobTermSize)
    append += ` gobterm=${window.gobTermSize.cols}x${window.gobTermSize.rows}`;
Module['arguments'] = [
    '-nographic', '-m', params.get('mem') || '512M',
    '-accel', 'tcg,tb-size=' + (params.get('tb') || '500'),
    '-L', '/pack/',
    '-nic', 'none',
    '-drive', 'if=virtio,format=raw,file=/pack/disk.ext4',
    '-kernel', '/pack/bzImage',
    '-append', append,
];
console.log('QEMU args: ' + JSON.stringify(Module['arguments']));
