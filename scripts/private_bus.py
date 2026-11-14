"""Private test bus with no dependency on the host's D-Bus configuration."""
import subprocess
from xml.sax.saxutils import escape


def start_private_bus(directory, environment):
    configuration = directory / 'bus.conf'
    configuration.write_text('''<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=''' + escape(str(directory)) + '''</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow own="*"/>
    <allow send_destination="*"/>
    <allow receive_sender="*"/>
  </policy>
</busconfig>
''')
    return subprocess.Popen(['dbus-daemon', '--config-file=' + str(configuration),
                             '--nofork', '--print-address=1'], env=environment,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            start_new_session=True)
