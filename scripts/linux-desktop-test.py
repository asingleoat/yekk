#!/usr/bin/env python3
"""Real chooser, XDND and monitor-profile tests on a private X server."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import selectors
import signal
import struct
import subprocess
import sys
import tempfile
import time
import zlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', default='zig-out/bin/yekk')
parser.add_argument('--output', default='dist/linux-desktop-integration.json')
parser.add_argument('--dialog-driver', choices=['zenity','portal'], default='zenity')
parser.add_argument('--case', help='run cases containing this text')
parser.add_argument('--fixture', type=Path, help='use a prebuilt linux-x11-fixture executable')
parser.add_argument('--instant-click',action='store_true',help='stress complete XTest click batches')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
os.chdir(root)
binary = Path(args.binary).resolve(strict=True)
output = Path(args.output)
output.parent.mkdir(parents=True, exist_ok=True)
report = {'cases': [], 'display': 'private Xvfb', 'dialog_driver':args.dialog_driver,'instant_click':args.instant_click,'performance_assertions': False}
report.update(binary=str(binary),binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
              source_sha256={str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(Path('src').rglob('*')) if path.is_file()},
              validation_sha256={name:hashlib.sha256(Path(name).read_bytes()).hexdigest() for name in ['scripts/linux-desktop-test.py','scripts/linux-x11-fixture.zig','scripts/supervise.py','flake.lock']})


def ready_line(process, timeout=15):
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    data = bytearray()
    try:
        deadline = time.monotonic() + timeout
        while b'\n' not in data:
            if time.monotonic() > deadline:
                raise TimeoutError('private service did not start')
            if selector.select(.1):
                block = os.read(process.stdout.fileno(), 4096)
                if not block:
                    raise RuntimeError('private service exited before readiness')
                data.extend(block)
        return data.decode().strip()
    finally:
        selector.close()


with tempfile.TemporaryDirectory(prefix='yekk-native-desktop-') as temporary:
    folder = Path(temporary)
    environment = dict(os.environ, SDL_VIDEO_DRIVER='x11', SDL_RENDER_DRIVER='software',
                       SDL_FILE_DIALOG_DRIVER=args.dialog_driver, GTK_USE_PORTAL='0', GSETTINGS_BACKEND='memory', GSK_RENDERER='cairo',
                       YEKK_CONFIG=str(folder/'absent-config'), XDG_CONFIG_HOME=str(folder/'config'),
                       XDG_DATA_HOME=str(folder/'data'), XDG_STATE_HOME=str(folder/'state'),
                       XDG_CACHE_HOME=str(folder/'cache'), XDG_RUNTIME_DIR=str(folder/'runtime'), YEKK_TEST_TIMEOUT='90')
    (folder/'runtime').mkdir(mode=0o700)
    if args.fixture:
        fixture = args.fixture.resolve(strict=True)
    else:
        subprocess.run(['zig','build','build-linux-fixtures','-Dtest-desktop=true','-Doptimize=ReleaseSafe','-j2'],check=True)
        fixture = root/'zig-out/bin/linux-x11-fixture'
    display_read, display_write = os.pipe()
    xserver = subprocess.Popen(['Xvfb','-displayfd',str(display_write),'-screen','0','1280x960x24','-dpi','192','-nolisten','tcp','-noreset','-ac'],
                               pass_fds=[display_write], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
    os.close(display_write)
    bus = None
    manager = None
    portal_processes = []
    portal_logs = []
    try:
        with os.fdopen(display_read,'rb') as stream:
            selector = selectors.DefaultSelector(); selector.register(stream,selectors.EVENT_READ)
            assert selector.select(15), 'private X server did not start'
            environment['DISPLAY'] = ':'+stream.readline().decode().strip()
            selector.close()
        from private_bus import start_private_bus
        bus = start_private_bus(folder, environment)
        environment['DBUS_SESSION_BUS_ADDRESS'] = ready_line(bus)
        manager_configuration=folder/'openbox.xml'
        manager_configuration.write_text('<openbox_config xmlns="http://openbox.org/3.4/rc"><focus><focusNew>yes</focusNew></focus><applications><application class="*"><decor>no</decor></application></applications></openbox_config>')
        manager=subprocess.Popen(['openbox','--sm-disable','--config-file',str(manager_configuration)],env=environment,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
        deadline=time.monotonic()+15
        while subprocess.run(['xdotool','get_desktop'],env=environment,capture_output=True,timeout=2).returncode:
            if manager.poll() is not None or time.monotonic()>deadline:
                raise RuntimeError('private window manager did not publish desktop readiness')
            time.sleep(.05)
        if args.dialog_driver == 'portal':
            portal = Path(os.environ['YEKK_TEST_PORTAL'])
            backend = Path(os.environ['YEKK_TEST_PORTAL_GTK'])
            configuration = folder/'config/xdg-desktop-portal'
            configuration.mkdir(parents=True)
            (configuration/'portals.conf').write_text('[preferred]\ndefault=gtk\n')
            environment['XDG_DATA_DIRS'] = str(backend/'share')+':'+str(portal/'share')
            environment['XDG_CURRENT_DESKTOP'] = 'YekkPrivateTest'
            subprocess.run(['dbus-update-activation-environment','DISPLAY','XDG_CURRENT_DESKTOP','XDG_DATA_DIRS'],env=environment,check=True,capture_output=True,timeout=10)
            for package,program in [(backend,'xdg-desktop-portal-gtk'),(portal,'xdg-desktop-portal')]:
                log=(folder/(program+'.log')).open('w+')
                portal_logs.append(log)
                portal_processes.append(subprocess.Popen([str(package/'libexec'/program),'--verbose'],env=environment,stdout=log,stderr=log,start_new_session=True))
                if program=='xdg-desktop-portal-gtk':
                    deadline=time.monotonic()+15
                    probe=['dbus-send','--session','--print-reply','--dest=org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus.NameHasOwner','string:org.freedesktop.impl.portal.desktop.gtk']
                    while b'true' not in subprocess.run(probe,env=environment,capture_output=True,timeout=2).stdout:
                        if time.monotonic()>deadline:
                            log.flush();log.seek(0);raise RuntimeError('private GTK portal failed: '+log.read())
                        time.sleep(.05)
            probe=['dbus-send','--session','--print-reply','--dest=org.freedesktop.portal.Desktop','/org/freedesktop/portal/desktop',
                   'org.freedesktop.DBus.Properties.Get','string:org.freedesktop.portal.FileChooser','string:version']
            deadline=time.monotonic()+15
            while subprocess.run(probe,env=environment,capture_output=True,timeout=2).returncode:
                if time.monotonic()>deadline:
                    for log in portal_logs:
                        log.flush();log.seek(0);print(log.read(),file=sys.stderr)
                    raise TimeoutError('private file chooser portal did not become available')
                time.sleep(.05)

        def run(command, **kwargs):
            return subprocess.run(list(map(str,command)), env=environment, check=True, capture_output=True, timeout=20, **kwargs)

        def windows():
            found = subprocess.run(['xdotool','search','--onlyvisible','--name','.*'],env=environment,capture_output=True,text=True,timeout=5)
            result = {}
            for identifier in found.stdout.split():
                pid = subprocess.run(['xdotool','getwindowpid',identifier],env=environment,capture_output=True,text=True,timeout=5)
                if pid.returncode:continue
                name = subprocess.run(['xdotool','getwindowname',identifier],env=environment,capture_output=True,text=True,timeout=5)
                if name.returncode == 0:
                    geometry = subprocess.run(['xdotool','getwindowgeometry','--shell',identifier],env=environment,capture_output=True,text=True,timeout=5)
                    fields = dict(line.split('=',1) for line in geometry.stdout.splitlines() if '=' in line)
                    # GTK also maps a tiny startup window named "zenity".
                    # It is not the file chooser and must never receive input.
                    if int(fields.get('WIDTH',0)) >= 160 and int(fields.get('HEIGHT',0)) >= 100:
                        result[identifier] = name.stdout.rstrip('\n')
            return result

        def key(identifier, value):
            run(['xdotool','windowactivate','--sync',identifier])
            run(['xdotool','key','--clearmodifiers',value])

        def dialog_ready(identifier):
            # A mapped GTK4 surface can precede widget creation/first paint.
            # Input sent during that interval is silently discarded by GTK.
            return max(json.loads(run([fixture,'pixel',identifier],text=True).stdout))>32

        def screenshot(suffix=''):
            ppm=run([fixture,'screen','root']).stdout
            magic,dimensions,maximum,rgb=ppm.split(b'\n',3)
            assert magic==b'P6' and maximum==b'255'
            width,height=map(int,dimensions.split())
            def chunk(kind,data):
                return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
            rows=b''.join(b'\0'+rgb[y*width*3:(y+1)*width*3] for y in range(height))
            output.with_name(output.stem+suffix+'.png').write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b''))

        def exercise(name, arguments, drive, expected_phase=1, prefetch=False):
            if args.case and args.case.casefold() not in name.casefold():
                phase[0]=expected_phase
                return
            run(['xdotool','keyup','q','Return','Right','Left','ctrl','shift','alt','super'])
            command = [sys.executable,'scripts/supervise.py','--relay',str(binary),'--alloc-stats','--decode-workers','2',*([] if prefetch else ['--no-prefetch']),
                       '--trace-events','--test-wait',*map(str,arguments)]
            process = subprocess.Popen(command,env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            selector = selectors.DefaultSelector()
            selector.register(process.stdout,selectors.EVENT_READ,'stdout'); selector.register(process.stderr,selectors.EVENT_READ,'stderr')
            captured = {'stdout':bytearray(),'stderr':bytearray()}
            try:
                deadline = time.monotonic()+85
                while selector.get_map():
                    if time.monotonic()>deadline: raise TimeoutError(name)
                    for event,_ in selector.select(.05):
                        data = os.read(event.fileobj.fileno(),65536)
                        if data:
                            captured[event.data].extend(data)
                            if args.case and event.data=='stdout':print(data.decode(errors='replace'),end='',flush=True)
                        else: selector.unregister(event.fileobj)
                    drive(captured['stdout'].decode()+(captured['stderr'].decode() if prefetch else ''), windows())
                result = {'name':name,'status':process.wait(timeout=5), **{key:value.decode() for key,value in captured.items()}}
                report['cases'].append(result); output.write_text(json.dumps(report,indent=2)+'\n')
                assert result['status']==0 and 'live_bytes=0' in result['stderr'] and phase[0]==expected_phase,result
                print(name+': passed',flush=True)
            except Exception as error:
                screenshot()
                report['cases'].append({'name':name,'error':repr(error), 'windows':windows(),
                                        'phase':phase[0],
                                        **{key:value.decode(errors='replace') for key,value in captured.items()}})
                output.write_text(json.dumps(report,indent=2)+'\n')
                print(json.dumps(report['cases'][-1],indent=2),file=sys.stderr,flush=True)
                raise
            finally:
                selector.close()
                if process.poll() is None:
                    process.send_signal(signal.SIGINT)
                    process.communicate(timeout=15)

        first = root/'tests/fixtures/rgb16-orientation1.tif'
        second = root/'tests/fixtures/rgb16-orientation6.tif'
        special = folder/"film '100%\n雪.png"
        special.symlink_to(root/'tests/fixtures/alpha.content')
        phase = [0]
        chooser_next_input = [0.0]
        def chooser(text, visible):
            viewers = {identifier:name for identifier,name in visible.items() if name.startswith(str(first)) or name.startswith(str(second))}
            dialogs = {identifier:name for identifier,name in visible.items() if identifier not in viewers and name != 'Yekk — loading'}
            # GTK can paint the surface before its location widget accepts
            # input. Retry the idempotent location entry until the new viewer
            # acknowledges it, rather than treating a fixed delay as readiness.
            if phase[0] in (0,1) and dialogs and time.monotonic() >= chooser_next_input[0] and dialog_ready(next(iter(dialogs))):
                identifier = next(iter(dialogs))
                key(identifier,'ctrl+l')
                time.sleep(.2)
                key(identifier,'ctrl+a')
                key(identifier,'BackSpace')
                run(['xdotool','type','--clearmodifiers','--delay','0',str(second)])
                time.sleep(.2)
                if args.case and phase[0]==0: screenshot('-location')
                key(identifier,'Return'); phase[0]=1
                chooser_next_input[0]=time.monotonic()+1
            elif phase[0]==1 and any(name.startswith(str(second)) for name in viewers.values()):
                assert any(name.startswith(str(first)) for name in viewers.values()), visible
                target = next(identifier for identifier,name in viewers.items() if name.startswith(str(second)))
                key(target,'q');phase[0]=2
        exercise('real native file chooser creates an independent window',['--test-keys','C-o',first],chooser,2)
        assert phase[0]==2

        phase[0]=0
        def drop(text,visible):
            viewers = {identifier:name for identifier,name in visible.items() if name.startswith(str(first)) or name.startswith(str(special))}
            if phase[0]==0 and any(name.startswith(str(first)) for name in viewers.values()):
                identifier = next(identifier for identifier,name in viewers.items() if name.startswith(str(first)))
                sent = run([fixture,'drop',identifier,special],text=True)
                assert 'DROP_SENT' in sent.stdout;phase[0]=1
            elif phase[0]==1 and any(name.startswith(str(special)) for name in viewers.values()):
                assert any(name.startswith(str(first)) for name in viewers.values()), visible
                key(next(identifier for identifier,name in viewers.items() if name.startswith(str(special))),'q');phase[0]=2
        exercise('real XDND preserves Unicode, percent, quote and newline path',[first],drop,2)
        assert phase[0]==2

        phase[0]=0
        def monitor(text,visible):
            viewers = {identifier:name for identifier,name in visible.items() if name.startswith(str(root/'tests/fixtures/linear-gray.png'))}
            if not viewers:return
            identifier = next(iter(viewers))
            pixel = json.loads(run([fixture,'pixel',identifier],text=True).stdout)
            if pixel not in report.setdefault('monitor_pixels',[]):
                report['monitor_pixels'].append(pixel);print('monitor pixel',phase[0],pixel,flush=True)
            if phase[0]==0 and pixel[0]==128:
                run([fixture,'profile','1'])
                # Focus notifications also refresh profiles on desktops that do
                # not emit a dedicated ICC notification for root changes.
                run(['xdotool','windowfocus',str(0)])
                run(['xdotool','windowfocus',identifier]);phase[0]=1
            elif phase[0]==1 and 52<=pixel[0]<=58:
                run([fixture,'profile','0']);key(identifier,'q');phase[0]=2
        exercise('real X11 monitor profile changes rebuild the output transform',['--zoom','10000',root/'tests/fixtures/linear-gray.png'],monitor,2)
        assert phase[0]==2
        phase[0]=0
        def cancel_chooser(text,visible):
            viewers = {identifier:name for identifier,name in visible.items() if name.startswith(str(first))}
            dialogs = {identifier:name for identifier,name in visible.items() if identifier not in viewers and name != 'Yekk — loading'}
            if phase[0]==0 and dialogs and dialog_ready(next(iter(dialogs))):
                key(next(iter(dialogs)),'Escape');phase[0]=1
            elif phase[0]==1 and not dialogs and viewers:
                key(next(iter(viewers)),'greater');phase[0]=2
            elif phase[0]==2 and 'rotation=1' in text and viewers:
                key(next(iter(viewers)),'q');phase[0]=3
        exercise('native chooser cancellation leaves the window interactive',['--test-keys','C-o',first],cancel_chooser,3)

        phase[0]=0
        def retired_dialog(text,visible):
            origin = {identifier:name for identifier,name in visible.items() if name.startswith(str(first))}
            child = {identifier:name for identifier,name in visible.items() if name.startswith(str(second))}
            dialogs = {identifier:name for identifier,name in visible.items() if identifier not in origin and identifier not in child and name != 'Yekk — loading'}
            if phase[0]==0 and origin:
                run([fixture,'drop',next(iter(origin)),second]);phase[0]=1
            elif phase[0]==1 and child:
                key(next(iter(origin)),'ctrl+o');phase[0]=2
            elif phase[0]==2 and dialogs and dialog_ready(next(iter(dialogs))):
                run([fixture,'close',next(iter(origin))]);phase[0]=3
            elif phase[0]==3 and not origin and child:
                if dialogs:key(next(iter(dialogs)),'Escape')
                phase[0]=4
            elif phase[0]==4 and not dialogs and child:
                key(next(iter(child)),'greater');phase[0]=5
            elif phase[0]==5 and 'rotation=1' in text and child:
                key(next(iter(child)),'q');phase[0]=6
        exercise('closing a chooser origin keeps another window and ignores the late callback',[first],retired_dialog,6)

        def click(button):
            if args.instant_click:run(['xdotool','click',str(button)])
            else:
                run(['xdotool','mousedown',str(button)]);time.sleep(.1);run(['xdotool','mouseup',str(button)])

        phase[0]=0
        def pointer_menu(text,visible):
            viewers={identifier:name for identifier,name in visible.items() if name.startswith(str(first)) or name.startswith(str(second))}
            if not viewers:return
            identifier=next(iter(viewers))
            if phase[0]==0 and 'VIEW ' in text:
                run(['xdotool','mousemove','--window',identifier,'20','20'])
                time.sleep(.05)
                click(3);phase[0]=1
            elif phase[0]==1 and text.count('VIEW ')>=2:
                screenshot('-menu')
                run(['xdotool','mousemove','--window',identifier,'40','32'])
                time.sleep(.05)
                click(1);phase[0]=2
            elif phase[0]==2 and 'scale=1.00000000' in text:
                assert 'VIEW index=1' not in text,text
                run(['xdotool','mousemove','--window',identifier,'500','350'])
                time.sleep(.05)
                click(1);phase[0]=3
            elif phase[0]==3 and 'VIEW index=1' in text:
                key(identifier,'q');phase[0]=4
        exercise('pointer menu invokes actual size without advancing until a later click',['--geometry','640x480','--zoom','50',first,second],pointer_menu,4)

        burst_folder=folder/'burst'
        burst_folder.mkdir()
        for name in ['a.tif','b.tif','c.tif','d.tif']:(burst_folder/name).symlink_to(first)
        phase[0]=0
        def rapid_clicks(text,visible):
            viewers={identifier:name for identifier,name in visible.items() if name.startswith(str(burst_folder))}
            if not viewers:return
            identifier=next(iter(viewers))
            if phase[0]==0 and 'VIEW ' in text:
                run(['xdotool','mousemove','--window',identifier,'500','350'])
                time.sleep(.05)
                run(['xdotool','click','--repeat','3','--delay','0','1']);phase[0]=1
            elif phase[0]==1 and 'VIEW index=3' in text:
                releases=[line for line in text.splitlines() if line.startswith('INPUT ') and 'kind=8 button=1 ' in line]
                assert len(releases)==3,text
                key(identifier,'q');phase[0]=2
        exercise('three batched clicks advance exactly three selections',[burst_folder],rapid_clicks,2)

        phase[0]=0
        focus_ids={}
        def focus_click(text,visible):
            viewers={identifier:name for identifier,name in visible.items() if name.startswith(str(burst_folder))}
            if phase[0]==0 and len(viewers)==1 and 'VIEW ' in text:
                origin=next(iter(viewers));focus_ids['origin']=origin
                run([fixture,'drop',origin,burst_folder]);phase[0]=1
            elif phase[0]==1 and len(viewers)==2:
                origin=focus_ids['origin'];child=next(identifier for identifier in viewers if identifier!=origin)
                focus_ids['child']=child
                for identifier,left in [(origin,40),(child,600)]:
                    run(['xdotool','windowsize',identifier,'400','300'])
                    run(['xdotool','windowmove',identifier,str(left),'40'])
                run(['xdotool','windowactivate','--sync',child])
                run(['xdotool','mousemove','--window',origin,'200','150'])
                time.sleep(.05);click(1);phase[0]=2
            elif phase[0]==2 and viewers.get(focus_ids['origin'],'').startswith(str(burst_folder/'b.tif')):
                assert viewers[focus_ids['child']].startswith(str(burst_folder/'a.tif')),viewers
                run(['xdotool','windowactivate','--sync',focus_ids['origin']])
                run(['xdotool','mousemove','--window',focus_ids['child'],'200','150'])
                time.sleep(.05);click(1);phase[0]=3
            elif phase[0]==3 and viewers.get(focus_ids['child'],'').startswith(str(burst_folder/'b.tif')):
                # X11 titles can update before the trace pipe is read. Wait for
                # both release events before checking the captured trace.
                releases=[line for line in text.splitlines() if line.startswith('INPUT ') and 'kind=8 button=1 ' in line]
                if len(releases)<2:return
                assert viewers[focus_ids['origin']].startswith(str(burst_folder/'b.tif')),viewers
                assert 'VIEW index=2' not in text,text
                assert len(releases)==2,text
                key(focus_ids['child'],'q');phase[0]=4
        exercise('clicking an unfocused window advances exactly once',['--geometry','400x300',burst_folder],focus_click,4)

        repeat_folder=folder/'key-repeat'
        repeat_folder.mkdir()
        for i in range(32):(repeat_folder/f'{i:02}.tif').symlink_to(first)
        phase[0]=0
        held={}
        def held_arrows(text,visible):
            viewers={identifier:name for identifier,name in visible.items() if name.startswith(str(repeat_folder))}
            positions=[int(value) for value in re.findall(r'^VIEW index=(\d+)',text,re.M)]
            if not viewers or not positions:return
            assert all(abs(b-a)<=1 for a,b in zip(positions,positions[1:])), 'held navigation skipped a displayed image'
            identifier=next(iter(viewers))
            now=time.monotonic()
            if phase[0]==0:
                run(['xdotool','windowactivate','--sync',identifier])
                run(['xdotool','keydown','Right'])
                held['started']=now;phase[0]=1
            elif phase[0]==1:
                assert now-held['started']<4,'holding Right did not repeat'
                if positions[-1]>=6:
                    run(['xdotool','keyup','Right'])
                    held['released']=now;phase[0]=2
            elif phase[0]==2 and now-held['released']>.25:
                held['right_stop']=positions[-1]
                held['settled']=now;phase[0]=3
            elif phase[0]==3 and now-held['settled']>.25:
                assert positions[-1]==held['right_stop'],'navigation continued after Right release'
                run(['xdotool','keydown','Left'])
                held['started']=now;phase[0]=4
            elif phase[0]==4:
                assert now-held['started']<4,'holding Left did not repeat'
                if positions[-1]<=held['right_stop']-4:
                    run(['xdotool','keyup','Left'])
                    held['released']=now;phase[0]=5
            elif phase[0]==5 and now-held['released']>.25:
                held['left_stop']=positions[-1]
                held['settled']=now;phase[0]=6
            elif phase[0]==6 and now-held['settled']>.25:
                assert positions[-1]==held['left_stop'],'navigation continued after Left release'
                key(identifier,'q');phase[0]=7
        exercise('held arrows repeatedly navigate and stop after release',['--no-wrap',repeat_folder],held_arrows,7)

        phase[0]=0
        def aggressive_prefetch(text,visible):
            if phase[0]!=0:return
            loads = re.findall(r'DECODE index=(\d+) speculative=(true|false) aggressive=(true|false)',text)
            ids = [int(record[0]) for record in loads]
            assert len(ids)==len(set(ids)), 'prefetch decoded an image twice'
            if len(ids)==len(list(repeat_folder.iterdir())):
                assert ids[:3]==[0,1,len(ids)-1], 'neighbors must load before distant images'
                assert all(record[2]=='true' for record in loads[3:]), loads
                target=next(identifier for identifier,name in visible.items() if name.startswith(str(repeat_folder)))
                key(target,'q');phase[0]=1
        exercise('aggressive prefetch loads the whole small list once',['--aggressive',repeat_folder],aggressive_prefetch,prefetch=True)

        saved_client={}
        phase[0]=0
        def geometry_save(text,visible):
            viewers = {identifier:name for identifier,name in visible.items() if name.startswith(str(first))}
            if phase[0]==0 and viewers:
                identifier=next(iter(viewers))
                run(['xdotool','windowsize',identifier,'720','480'])
                run(['xdotool','windowmove',identifier,'60','70']);phase[0]=1
            elif phase[0]==1 and text.count('VIEW ')>1:
                identifier=next(iter(viewers))
                geometry=run(['xdotool','getwindowgeometry','--shell',identifier],text=True).stdout
                saved_client.update(line.split('=',1) for line in geometry.splitlines() if '=' in line)
                key(identifier,'q');phase[0]=2
        exercise('normal window geometry is saved by the closing worker',[first],geometry_save,2)
        if not args.case or args.case.casefold() in 'normal window geometry is saved by the closing worker':
            stored=(folder/'state/yekk/window').read_text().split()
            assert stored==['1','720','480',saved_client['X'],saved_client['Y']],stored
        phase[0]=0
        def geometry_restore(text,visible):
            viewers = {identifier:name for identifier,name in visible.items() if name.startswith(str(first))}
            if phase[0]==0 and viewers:
                identifier=next(iter(viewers))
                geometry=run(['xdotool','getwindowgeometry','--shell',identifier],text=True).stdout
                assert all(field+'='+saved_client[field] in geometry.splitlines() for field in ['WIDTH','HEIGHT','X','Y']),geometry
                key(identifier,'q');phase[0]=1
        exercise('normal window geometry is restored on the next invocation',[first],geometry_restore)

        report['passed']=True;output.write_text(json.dumps(report,indent=2)+'\n')
        print(output)
    finally:
        for child in [*reversed(portal_processes),manager,bus,xserver]:
            if child is not None and child.poll() is None:
                os.killpg(child.pid,signal.SIGTERM)
                try: child.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid,signal.SIGKILL);child.communicate(timeout=5)
        for log in portal_logs:log.close()
