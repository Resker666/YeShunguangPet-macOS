#!/usr/bin/env python3
"""Bounded CPU/RSS sampling for this repository's own macOS App only."""
from pathlib import Path
import argparse, ctypes, json, math, os, subprocess, time
ROOT=Path(__file__).resolve().parents[1]
EXPECTED=(ROOT/'dist/YeShunguangPet.app/Contents/MacOS/YeShunguangPet').resolve()

def snapshot(pid):
    # ps comm is truncated to 15 bytes on this macOS build, even with -ww.
    library=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
    library.proc_pidpath.argtypes=[ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32]
    library.proc_pidpath.restype=ctypes.c_int
    buffer=ctypes.create_string_buffer(4096)
    if library.proc_pidpath(pid,buffer,len(buffer))<=0: return None
    if Path(os.fsdecode(buffer.value)).resolve()!=EXPECTED: raise ValueError('PID is not this packaged App')
    result=subprocess.run(['ps','-p',str(pid),'-o','time=','-o','rss=','-o','lstart='],capture_output=True,text=True,env=dict(os.environ,LC_ALL='C'))
    if result.returncode or not result.stdout.strip(): return None
    cpu,rss,started=result.stdout.strip().split(maxsplit=2)
    days=0
    if '-' in cpu:
        day,cpu=cpu.split('-',1);days=int(day)
    seconds=0.0
    for part in cpu.split(':'): seconds=seconds*60+float(part)
    return dict(cpuSeconds=seconds+days*86400,rssKiB=int(rss),started=started,monotonicSeconds=time.monotonic())

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid',type=int,required=True);parser.add_argument('--duration',type=float,default=600);parser.add_argument('--interval',type=float,default=5);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    if args.pid<=0 or not all(math.isfinite(x) and x>0 for x in [args.duration,args.interval]): parser.error('PID, duration and interval must be positive and finite')
    first=snapshot(args.pid)
    if first is None: parser.error('App is not running')
    samples=[first]; start=time.monotonic(); next_report=60
    completed=True
    while time.monotonic()-start<args.duration:
        time.sleep(min(args.interval,max(0,args.duration-(time.monotonic()-start))))
        row=snapshot(args.pid)
        if row is None or row['started']!=first['started']:
            completed=False;break
        samples.append(row)
        elapsed=time.monotonic()-start
        if elapsed>=next_report:
            print(f'Sampled {elapsed:.1f}s; RSS {row["rssKiB"]/1024:.1f} MiB',flush=True);next_report+=60
    span=samples[-1]['monotonicSeconds']-samples[0]['monotonicSeconds']
    summary=dict(pid=args.pid,completed=completed and span>=args.duration,requestedSeconds=args.duration,elapsedSeconds=span,sampleCount=len(samples),cpuSingleCorePercent=100*(samples[-1]['cpuSeconds']-first['cpuSeconds'])/span if span else 0,rssMiBMin=min(r['rssKiB'] for r in samples)/1024,rssMiBMax=max(r['rssKiB'] for r in samples)/1024,samples=samples)
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps({k:v for k,v in summary.items() if k!='samples'}),flush=True)
    return 0 if summary['completed'] else 1
if __name__=='__main__': raise SystemExit(main())
