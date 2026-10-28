from pathlib import Path
import contextlib
import hashlib
import importlib
import io
import json
import os
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ADAPTER = Path(__file__).resolve().parents[2] / 'Resources/LocalVoice'
sys.path.insert(0, str(ADAPTER))
import probe


class EngineProbeTests(unittest.TestCase):
    def testProbeValidatesOfflineWithoutVoiceOrDownloads(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'engine'; source = root / 'source'; source.mkdir(parents=True)
            (source / 'asset').write_bytes(b'base')
            assets = dict(profile='gpt-sovits-v2proplus-cpu1', sourceCommit='b4570b876f5c086819ba84e3215472733c6a7b70', files=[dict(path='source/asset', bytes=4, sha256=hashlib.sha256(b'base').hexdigest())])
            (root / 'engine-assets.json').write_text(json.dumps(assets))
            calls = []
            def stub(name):
                calls.append(name)
                if name == 'socket': raise AssertionError('unexpected import')
                return types.SimpleNamespace(disable_telemetry_events=lambda:None, set_num_threads=lambda n:None,
                    set_num_interop_threads=lambda n:None, data=types.SimpleNamespace(path=[]),
                    TTS=lambda *a: self.fail('model must not load'))
            before = {str(p):p.read_bytes() for p in source.rglob('*') if p.is_file()}
            with patch.object(probe.sys, 'version_info', (3,12,14)), patch.object(probe.platform, 'machine', return_value='arm64'), patch.object(probe.importlib, 'import_module', side_effect=stub), patch.object(probe, 'install_network_guard', return_value=lambda:None):
                result = probe.check_engine(root, Path(tmp)/'cache')
            self.assertEqual(result['pythonVersion'], '3.12.14')
            self.assertIn('TTS_infer_pack.TTS', calls)
            self.assertEqual(before, {str(p):p.read_bytes() for p in source.rglob('*') if p.is_file()})
            self.assertFalse((root/'voice.json').exists())
            (source/'asset').write_bytes(b'bad')
            with patch.object(probe.sys, 'version_info', (3,12,14)), patch.object(probe.platform, 'machine', return_value='arm64'):
                with self.assertRaises(ValueError): probe.check_engine(root, Path(tmp)/'cache')

    def test_wrong_platform_and_python_are_explicit(self):
        for version, machine in [((3,11,0),'arm64'), ((3,12,0),'x86_64')]:
            with patch.object(probe.sys,'version_info',version), patch.object(probe.platform,'machine',return_value=machine):
                with self.assertRaisesRegex(RuntimeError, 'Python|Apple Silicon'): probe.check_engine(Path('/missing'),Path('/missing'))

    def testParentPipeEOFEndsBlockedProbe(self):
        code = "import sys,time;sys.path.insert(0,sys.argv[1]);import probe;probe.check_engine=lambda *a:time.sleep(60);probe.main(['--engine-root','/unused','--cache-root','/unused','--request-id','1E185D19-288B-42DE-9A76-61C85356731C'])"
        child = subprocess.Popen([sys.executable,'-u','-c',code,str(ADAPTER)], stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            child.stdin.close(); child.wait(timeout=4)
            self.assertNotEqual(child.returncode,0)
        finally:
            if child.poll() is None:child.kill();child.wait()
            child.stdout.close();child.stderr.close()

if __name__ == '__main__': unittest.main()
