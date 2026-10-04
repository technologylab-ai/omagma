#!/usr/bin/env python3
"""Load the real Omarchy base types with our plugin, offscreen and closed.

Only temporary copies/symlinks are created. Never edits installed shell config.
This verifies host type/binding compatibility, not Wayland focus or placement.
"""
import json, os, pathlib, shutil, subprocess, tempfile, time, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='omagma-host-') as directory:
    dst = pathlib.Path(directory)
    for name in ('BarWidget.qml', 'Service.qml', 'Model.mjs'):
        shutil.copy2(ROOT / name, dst / name)
    shutil.copytree(ROOT / 'qml', dst / 'qml')
    shutil.copytree(ROOT / 'assets', dst / 'assets')
    for name in ('Ui', 'Commons'):
        (dst / name).symlink_to(pathlib.Path('/usr/share/omarchy/shell') / name, target_is_directory=True)
    binary = json.dumps(str(ROOT / 'zig-out/bin/omagma'))
    (dst / 'shell.qml').write_text('''import QtQuick
import Quickshell
import "." as Gmail
ShellRoot {
  id: root
  Gmail.Service { id: mailService }
  QtObject {
    id: shellApi
    function firstPartyServiceFor(id) { return mailService }
  }
  QtObject {
    id: fakeBar
    property var shell: shellApi
    property bool vertical: false
    property bool foregroundAnimationEnabled: false
    property int barSize: 38
    property string position: "top"
    property string fontFamily: "sans-serif"
    property color foreground: "#eeeeee"
    property color barForeground: "#eeeeee"
    property color background: "#101315"
    property color urgent: "#ee5555"
    property var activePopout: null
    property var clickTargets: []
    function registerClickTarget(target) {}
    function unregisterClickTarget(target) {}
    function hideTooltip(target) {}
    function requestPopout(target) { activePopout = target }
    function releasePopout(target) { activePopout = null }
  }
  FloatingWindow {
    visible: false
    implicitWidth: 1000
    implicitHeight: 38
    Gmail.BarWidget { bar: fakeBar; settings: ({ daemonPath: BINARY, fixtures: true }) }
  }
}
'''.replace('BINARY', binary))
    wayland_closed = '--wayland-closed' in sys.argv
    env = dict(os.environ)
    if not wayland_closed: env['QT_QPA_PLATFORM'] = 'offscreen'
    if not wayland_closed:
        env.pop('WAYLAND_DISPLAY', None)
        env.pop('HYPRLAND_INSTANCE_SIGNATURE', None)
    log = ROOT / 'tests/results/ui-host.log'
    with log.open('w') as output:
        process = subprocess.Popen(['quickshell', '--path', str(dst), '--no-color'], stdout=output, stderr=subprocess.STDOUT, env=env)
        try:
            time.sleep(4)
            assert process.poll() is None, 'Host probe exited; inspect log'
        finally:
            if process.poll() is None: process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
    text = log.read_text()
    assert 'Configuration Loaded' in text, text
    assert all(word not in text for word in ('TypeError', 'ReferenceError', 'Failed to load configuration', 'is not a type', 'Cannot assign', 'Type KeyboardPanel unavailable', 'Type MailView unavailable', 'Property value set multiple times', 'Cannot open', 'Error decoding')), text
    print('PASS real Omarchy host types, all surfaces closed, ' + ('Wayland' if wayland_closed else 'offscreen'))
