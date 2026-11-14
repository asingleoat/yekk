#!/usr/bin/env python3
"""Check memory admission inside an isolated systemd user cgroup, without filling RAM."""
import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', default='zig-out/bin/yekk')
parser.add_argument('--output', default='dist/linux-memory-admission.json')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
os.chdir(root)
binary = Path(args.binary).resolve(strict=True)
output = Path(args.output)
output.parent.mkdir(parents=True, exist_ok=True)
if not shutil.which('systemd-run'):
    raise SystemExit('systemd user cgroups are required for this test')
with tempfile.TemporaryDirectory(prefix='yekk-cgroup-') as temporary:
    folder = Path(temporary)
    image = folder/'sparse.tif'
    width = height = 32768
    entries = [(256,4,1,width),(257,4,1,height),(258,3,3,0),(259,3,1,1),
               (262,3,1,2),(273,4,1,0),(277,3,1,3),(278,4,1,height),
               (279,4,1,width*height*3),(284,3,1,1)]
    samples = 8+2+len(entries)*12+4
    data = samples+6
    header = bytearray(b'II'+struct.pack('<HIH',42,8,len(entries)))
    for tag,kind,count,value in entries:
        if tag == 258: value = samples
        if tag == 273: value = data
        header.extend(struct.pack('<HHII',tag,kind,count,value))
    header.extend(struct.pack('<IHHH',0,8,8,8))
    with image.open('wb') as stream:
        stream.write(header)
        stream.truncate(data+width*height*3)
    environment = dict(os.environ, YEKK_CONFIG=str(folder/'absent-config'), XDG_STATE_HOME=str(folder/'state'))
    # This is a test sandbox limit, never an application memory policy. Its
    # sparse source exceeds the limit before a pixel allocation is attempted.
    unit = 'yekk-admission-'+uuid.uuid4().hex
    command = ['systemd-run','--user','--wait','--pipe','--collect',
               '--unit='+unit,
               '--property=MemoryMax=512M','--property=MemorySwapMax=0',
               str(binary),'--alloc-stats','--decode-workers','2','--benchmark',str(image)]
    try:
        result = subprocess.run(command,env=environment,text=True,capture_output=True,timeout=45)
    except subprocess.TimeoutExpired:
        subprocess.run(['systemctl','--user','stop',unit],capture_output=True,timeout=10)
        raise
    report = {'command':command,'source_pixels':width*height,'source_sparse_bytes':image.stat().st_blocks*512,
              'test_cgroup_memory_max':512*1024**2,'status':result.returncode,'stdout':result.stdout,'stderr':result.stderr,
              'performance_assertions':False}
    output.write_text(json.dumps(report,indent=2)+'\n')
    assert result.returncode != 0 and 'OutOfMemory' in result.stderr,report
    assert 'live_bytes=0' in result.stderr and 'status=9/KILL' not in result.stderr,report
    report['passed']=True
    output.write_text(json.dumps(report,indent=2)+'\n')
    print(output)
