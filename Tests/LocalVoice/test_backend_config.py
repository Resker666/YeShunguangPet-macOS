from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Resources/LocalVoice"))
from gpt_sovits_backend import GPTSoVITSBackend, install_network_guard, validate_samples


class BackendConfigTests(unittest.TestCase):
    def test_all_zh_config_and_temp_yaml_do_not_mutate_upstream(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            backend = GPTSoVITSBackend(root / "engine", root / "voice", root / "work")
            config = backend.configuration()
            self.assertEqual(config["custom"]["device"], "cpu")
            self.assertIs(config["custom"]["is_half"], False)
            self.assertEqual(config["custom"]["version"], "v2ProPlus")
            self.assertEqual(backend.config_path.parent, root / "work")
            inputs = backend.inputs("测试文本", 1.3)
            for key, value in {"text_lang": "all_zh", "prompt_lang": "all_zh", "text_split_method": "cut0", "batch_size": 1, "streaming_mode": False, "use_cuda_graph": False, "speed_factor": 1.3}.items():
                self.assertEqual(inputs[key], value)
            self.assertNotIn("torch", sys.modules)

    def test_empty_oversized_and_wrong_rate_audio_is_rejected(self):
        for rate, frames in ((32000, 0), (32000, 32000 * 240 + 1), (16000, 32000)):
            with self.assertRaises(ValueError):
                validate_samples(rate, frames)
        validate_samples(32000, 32000)

    def test_network_guard_blocks_internet_without_touching_a_real_endpoint(self):
        # Restore patches so the stdlib suite's own process tools remain unaffected.
        undo = install_network_guard()
        try:
            import socket
            with self.assertRaises(OSError):
                socket.getaddrinfo("must-not-resolve.example", 443)
            with socket.socket() as connection:
                with self.assertRaises(OSError):
                    connection.connect(("127.0.0.1", 443))
        finally:
            undo()


if __name__ == "__main__":
    unittest.main()
