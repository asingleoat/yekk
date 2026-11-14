#!/usr/bin/env python3
"""Bounded high-resolution navigation checks on a private X server."""
import argparse,hashlib,json,os,re,selectors,signal,subprocess,sys,tempfile,time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--before',type=Path,required=True);p.add_argument('--after',type=Path,required=True)
p.add_argument('--images',type=Path,nargs=2,required=True);p.add_argument('--repeats',type=int,default=3)
p.add_argument('--output',type=Path,required=True);p.add_argument('--software',action='store_true')
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root)
if a.output.exists():p.error('refusing to overwrite existing evidence')
report={'display':'private Xvfb; no input reaches the real desktop','software':a.software,'runs':[],'binary_sha256':{name:hashlib.sha256(path.read_bytes()).hexdigest() for name,path in [('before',a.before),('after',a.after)]}}
def identity(path):
 s=path.stat();return [s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns]
report['sources_before']={str(x):identity(x) for x in a.images}
def save():a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(report,indent=2)+'\n')
with tempfile.TemporaryDirectory(prefix='yekk-prefetch-x11-') as temporary:
 folder=Path(temporary);keys=folder/'keys';keys.write_text('zoom_default v\n')
 read,write=os.pipe();server=subprocess.Popen(['Xvfb','-displayfd',str(write),'-screen','0','1400x1000x24','-nolisten','tcp','-noreset','-ac'],pass_fds=[write],stderr=subprocess.PIPE,start_new_session=True);os.close(write)
 try:
  with os.fdopen(read,'rb') as stream:
   ready=selectors.DefaultSelector();ready.register(stream,selectors.EVENT_READ);assert ready.select(15),'Xvfb start timeout';display=':'+stream.readline().decode().strip();ready.close()
  env=dict(os.environ,DISPLAY=display,SDL_VIDEO_DRIVER='x11',YEKK_CONFIG=str(folder/'none'),XDG_CONFIG_HOME=str(folder/'config'),YEKK_TEST_TIMEOUT='70')
  if a.software:env['SDL_RENDER_DRIVER']='software'
  else:env.pop('SDL_RENDER_DRIVER',None)
  def run(variant,case):
   binary=(a.before if variant=='before' else a.after).resolve()
   cmd=[sys.executable,'scripts/supervise.py','--relay',str(binary),'--trace-events','--test-wait','--alloc-stats','--geometry','960x640','--keys',str(keys),*map(str,a.images)]
   proc=subprocess.Popen(cmd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
   sel=selectors.DefaultSelector();sel.register(proc.stdout,selectors.EVENT_READ,'stdout');sel.register(proc.stderr,selectors.EVENT_READ,'stderr')
   chunks={'stdout':bytearray(),'stderr':bytearray()};pending={'stdout':b'','stderr':b''};events=[];deadline=time.monotonic()+70
   def pump(timeout=.1):
    assert time.monotonic()<deadline,'supervised case deadline'
    for item,_ in sel.select(timeout):
     data=os.read(item.fileobj.fileno(),65536)
     if not data:sel.unregister(item.fileobj);continue
     name=item.data;chunks[name].extend(data);pending[name]+=data
     while b'\n' in pending[name]:
      line,pending[name]=pending[name].split(b'\n',1);events.append(line.decode(errors='replace'))
   def wait(predicate,history=False):
    start=0 if history else len(events)
    while True:
     for line in events[start:]:
      if predicate(line):return line
     start=len(events);pump()
     if proc.poll() is not None and not sel.get_map():raise RuntimeError('viewer exited early')
   def view():return wait(lambda s:s.startswith('VIEW '))
   def key(value):subprocess.run(['xdotool','key','--clearmodifiers',value],env=env,check=True,timeout=5)
   record={'variant':variant,'case':case,'command':cmd,'views':[]}
   try:
    record['views'].append(view())
    windows=subprocess.check_output(['xdotool','search','--onlyvisible','--name','.*'],env=env,text=True).splitlines()
    window=next(x for x in windows if subprocess.run(['xdotool','getwindowpid',x],env=env,capture_output=True).returncode==0)
    subprocess.run(['xdotool','windowfocus','--sync',window],env=env,check=True,timeout=5)
    if variant=='after':wait(lambda s:s.startswith('CACHED index=1 ') and 'fitted=true' in s,True)
    else:wait(lambda s:s.startswith('DECODE_READY index=1 '),True)
    if case=='first-neighbor':
     key('Right');record['views'].append(view());key('Left');record['views'].append(view())
    elif case=='zoom-return':
     key('Up');record['views'].append(view());key('v');record['views'].append(view());key('Right');record['views'].append(view());key('Left');record['views'].append(view())
    else:
     key('Right');record['views'].append(view());key('Left');record['views'].append(view())
     key('Up')
     wait(lambda s:s.startswith('PREPARE index=0 ') and 'prefetch=false' in s)
     key('Right');record['views'].append(wait(lambda s:s.startswith('VIEW index=1 ')))
    key('q')
    while sel.get_map():pump()
    record.update(status=proc.wait(timeout=5),stdout=chunks['stdout'].decode(errors='replace'),stderr=chunks['stderr'].decode(errors='replace'))
    assert record['status']==0,record
    assert 'live_bytes=0' in record['stderr'],record
    report['runs'].append(record);save();print(variant,case,record['views'][-1],flush=True)
   finally:
    if proc.poll() is None:proc.terminate();proc.wait(timeout=8)
    sel.close()
  for repeat in range(a.repeats):
   for case in ['first-neighbor','zoom-return','ready-during-render']:
    for variant in (['before','after'] if repeat%2==0 else ['after','before']):run(variant,case)
 finally:
  os.killpg(server.pid,signal.SIGTERM);server.wait(timeout=5)
report['sources_after']={str(x):identity(x) for x in a.images};assert report['sources_after']==report['sources_before'];report['completed']=True;save()
