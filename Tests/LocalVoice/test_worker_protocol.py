import json
from pathlib import Path
import sys
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Resources/LocalVoice"))
from worker_protocol import decode_command


class ProtocolTests(unittest.TestCase):
    def command(self, **values):
        command = {"v": 1, "command": "generate", "sessionID": str(uuid.uuid4()), "requestID": str(uuid.uuid4()), "text": "你好", "speedFactor": 1.0}
        command.update(values)
        return (json.dumps(command, ensure_ascii=False) + "\n").encode()

    def test_partial_or_oversize_line_is_bounded(self):
        valid = self.command()
        with self.assertRaises(ValueError):
            decode_command(valid[:-1])
        exact = valid[:-1] + b" " * (65536 - len(valid)) + b"\n"
        self.assertEqual(decode_command(exact)["text"], "你好")
        with self.assertRaises(ValueError):
            decode_command(exact + b"\n")

    def test_invalid_values_are_rejected(self):
        for values in ({"v": True}, {"v": 1.0}, {"speedFactor": True}, {"speedFactor": 0.69}, {"speedFactor": 1.31}, {"extra": "x"},
                       {"text": "中" * 601}, {"text": "😀" * 301}, {"text": "\0"}, {"requestID": "../outside"}, {"sessionID": "bad"}):
            with self.subTest(values=list(values)):
                with self.assertRaises(ValueError):
                    decode_command(self.command(**values))
        for speed in (0.7, 1.3):
            self.assertEqual(decode_command(self.command(speedFactor=speed))["speedFactor"], speed)
        duplicate = self.command().replace(b'"v": 1', b'"v": 1,"v":1')
        with self.assertRaises(ValueError):
            decode_command(duplicate)


if __name__ == "__main__":
    unittest.main()
