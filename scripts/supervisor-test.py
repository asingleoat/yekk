#!/usr/bin/env python3
"""Distinguish a pre-exec launch helper from a newly executed viewer copy."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

if not sys.platform.startswith('linux'):
    raise SystemExit('Linux fork/exec guard check requires /proc')
supervisor = Path(__file__).with_name('supervise.py').resolve()
with tempfile.TemporaryDirectory(prefix='yekk-supervisor-') as temporary:
    fixture = Path(temporary) / 'process.py'
    fixture.write_text('''import os, sys, time
if sys.argv[1] == 'child':
    time.sleep(10)
else:
    child = os.fork()
    if child == 0:
        if sys.argv[1] == 'launch':
            time.sleep(0.25)
            os.execl('/usr/bin/true', 'true')
        os.execl(sys.executable, sys.executable, __file__, 'child')
    os.waitpid(child, 0)
''')
    for mode, expected in [('launch', 0), ('recursive', 1)]:
        result = subprocess.run([sys.executable, str(supervisor), sys.executable, str(fixture), mode],
                                env=dict(os.environ, YEKK_TEST_TIMEOUT='3'),
                                capture_output=True, text=True, timeout=5)
        assert result.returncode == expected, result.stderr
        assert ('regression blocked' in result.stderr) == (mode == 'recursive'), result.stderr
        print(mode + ' fork/exec guard: passed')
