import subprocess, sys, time
def best(cmd, n=5):
    ts=[]
    for _ in range(n):
        t0=time.perf_counter()
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ts.append(time.perf_counter()-t0)
    return min(ts), sum(ts)/len(ts)
for label, cmd in [(a.split('=')[0], a.split('=')[1]) for a in sys.argv[1:]]:
    b, m = best([cmd])
    print(f"{label:<28} best {b:6.3f}s   mean {m:6.3f}s")
