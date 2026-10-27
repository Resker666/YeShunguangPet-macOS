import json
from pathlib import Path
import selectors
import subprocess
import sys
import unittest
import uuid

RESOURCES = Path(__file__).resolve().parents[2] / "Resources/LocalVoice"


class WorkerTests(unittest.TestCase):
    def start(self, blocked=False, block_generate=False):
        self.session = str(uuid.uuid4())
        script = f'''
import sys,threading
from pathlib import Path
sys.path.insert(0,{str(RESOURCES)!r})
from worker_protocol import serve
class Backend:
    session_id={self.session!r}
    work_root=Path('/unused-test')
    def initialize(self):
        print("backend initialization noise")
        if {blocked!r}:
            sys.stderr.write("initializing\\n");sys.stderr.flush();threading.Event().wait()
    def generate(self,text,speed_factor,output):
        print("private input must not leak: "+text)
        if {block_generate!r}:
            sys.stderr.write("generating\\n");sys.stderr.flush();threading.Event().wait()
        return {{"sampleRate":32000,"frames":32000}}
raise SystemExit(serve(sys.stdin.buffer,sys.stdout,Backend))
'''
        process = subprocess.Popen([sys.executable, "-u", "-c", script], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=3)
        self.addCleanup(cleanup)
        return process

    def line(self, pipe):
        with selectors.DefaultSelector() as selector:
            selector.register(pipe, selectors.EVENT_READ)
            self.assertTrue(selector.select(timeout=4), "worker response timeout")
            return pipe.readline()

    def send(self, process, value):
        process.stdin.write((json.dumps(value, ensure_ascii=False) + "\n").encode())
        process.stdin.flush()

    def test_stdout_contains_protocol_only_even_when_backend_prints(self):
        process = self.start()
        ready = json.loads(self.line(process.stdout))
        self.assertEqual(ready["event"], "ready")
        request = str(uuid.uuid4())
        self.send(process, {"v": 1, "command": "generate", "sessionID": self.session, "requestID": request, "text": "仅测试新文本", "speedFactor": 1.0})
        result = json.loads(self.line(process.stdout))
        self.assertEqual(result["event"], "result")
        self.assertEqual(result["requestID"], request)
        self.assertNotIn("text", result)
        self.send(process, {"v": 1, "command": "shutdown", "sessionID": self.session})
        self.assertEqual(process.wait(timeout=3), 0)

    def test_eof_exits_during_blocked_initialization(self):
        process = self.start(blocked=True)
        self.assertEqual(self.line(process.stderr), b"initializing\n")
        process.stdin.close(); process.stdin = None
        self.assertEqual(process.wait(timeout=3), 0)

    def test_shutdown_exits_during_blocked_initialization(self):
        process = self.start(blocked=True)
        self.assertEqual(self.line(process.stderr), b"initializing\n")
        self.send(process, {"v": 1, "command": "shutdown", "sessionID": self.session})
        self.assertEqual(process.wait(timeout=3), 0)

    def test_invalid_request_never_calls_backend(self):
        process = self.start()
        self.assertEqual(json.loads(self.line(process.stdout))["event"], "ready")
        self.send(process, {"v": 1, "command": "generate", "sessionID": str(uuid.uuid4()), "requestID": str(uuid.uuid4()), "text": "secret", "speedFactor": 1})
        error = json.loads(self.line(process.stdout))
        self.assertEqual(error["code"], "protocol")
        self.assertNotIn("secret", json.dumps(error))
        self.assertEqual(process.wait(timeout=3), 1)

    def test_eof_exits_during_blocked_generation(self):
        process = self.start(block_generate=True)
        self.assertEqual(json.loads(self.line(process.stdout))["event"], "ready")
        self.send(process, {"v": 1, "command": "generate", "sessionID": self.session, "requestID": str(uuid.uuid4()), "text": "仅测试", "speedFactor": 1})
        self.assertEqual(self.line(process.stderr), b"generating\n")
        process.stdin.close(); process.stdin = None
        self.assertEqual(process.wait(timeout=3), 0)


if __name__ == "__main__":
    unittest.main()
