import hashlib
import io
import json
from pathlib import Path
import struct
import wave

COMMIT = 'a' * 40
APP_COMMIT = '375ff361e02de30f5ccab8a03e9f5b3412d44800'
UPSTREAM = 'b4570b876f5c086819ba84e3215472733c6a7b70'
ENGINE = 'YeShunguangPet-VoiceEngine-1.0.0-macOS-arm64.dmg'
VOICE = 'YeShunguangPet-Voice-hutao-pilot-e1.zip'
FILES = {ENGINE, ENGINE + '.sha256', VOICE, VOICE + '.sha256', 'voice-assets.json', '安装说明.md'}

def sha(data):
    return hashlib.sha256(data).hexdigest()

def voice_folder(root):
    folder = Path(root) / 'source-voice'
    folder.mkdir()
    model = b'not a pickled model'
    buffer = io.BytesIO()
    with wave.open(buffer, 'wb') as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(32000)
        f.writeframes(struct.pack('<h', 1) * 96000)
    reference = buffer.getvalue()
    manifest = dict(schemaVersion=1, id='hutao-pilot-e1', name='胡桃 · 试用 e1',
                    language='zh-CN', engineProfile='gpt-sovits-v2proplus-cpu1',
                    promptText='你好。', suggestedCharacterID='hutao',
                    model=dict(file='s2.pth', bytes=len(model), sha256=sha(model)),
                    reference=dict(file='reference.wav', bytes=len(reference), sha256=sha(reference)))
    for name, data in [('s2.pth', model), ('reference.wav', reference)]:
        (folder / name).write_bytes(data)
    (folder / 'voice.json').write_text(json.dumps(manifest, ensure_ascii=False))
    return folder

def engine_folder(root):
    folder = Path(root) / 'engine'
    (folder / 'payload/runtime/bin').mkdir(parents=True)
    python = folder / 'payload/runtime/bin/python3.12'
    python.write_bytes(b'not executable by tests'); python.chmod(0o755)
    empty = folder / 'payload/empty.txt'; empty.write_bytes(b'')
    records = [dict(path='empty.txt', bytes=0, sha256=sha(b''), executable=False),
               dict(path='runtime/bin/python3.12', bytes=python.stat().st_size,
                    sha256=sha(python.read_bytes()), executable=True)]
    manifest = dict(schemaVersion=1, id='gpt-sovits-macos-arm64', version='1.0.0',
                    name='本地中文语音引擎', architecture='arm64', minimumOS='14.0',
                    pythonVersion='3.12.14', profile='gpt-sovits-v2proplus-cpu1',
                    sourceCommit=UPSTREAM, files=records)
    (folder / 'engine.json').write_text(json.dumps(manifest, ensure_ascii=False))
    return folder

def inputs(root):
    root = Path(root)
    folder = voice_folder(root)
    image = root / 'input.dmg'; image.write_bytes(b'opaque DMG fixture; never mounted in unit tests')
    readme = root / 'readme.md'; readme.write_text('需要 App 0.7.0。解压后导入文件夹。')
    notices = root / 'notices.md'; notices.write_text('上游与胡桃来源；部分分发声明未核实。')
    return folder, image, readme, notices

def bundle(module, root, commit=COMMIT):
    root = Path(root)
    voice, image, readme, notices = inputs(root)
    archive = module.build_voice_zip(voice, root / 'input.zip', notices=notices)
    return module.build_bundle(image, archive, root / 'assets', tools_commit=commit,
                               app_commit=APP_COMMIT, readme=readme,
                               provenance={'engineManifestSHA256': 'b' * 64,
                                           'enginePayloadFiles': 2, 'enginePayloadBytes': 23,
                                           'sourceNotice': '测试来源；未核实项保留'})
