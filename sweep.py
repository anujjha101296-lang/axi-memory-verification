import subprocess, re, json, collections
def run(args):
    o=subprocess.run(["./obj/Vtb_top"]+args,capture_output=True,text=True,timeout=300).stdout
    m=re.search(r"SUMMARY .*",o).group(0); d=dict(x.split("=") for x in m.split()[1:] if "=" in x)
    kinds=re.findall(r"^P?KIND (\S+) (\d+)",o,re.M); return d,kinds,o
res={}
names={0:"clean",1:"strobes ignored",2:"FIXED treated as INCR",3:"RLAST one beat early",4:"last write beat dropped",
       5:"OOR write not flagged",6:"read data advances during stall",7:"INCR wraps at 256B",8:"WRAP burst not flagged"}
for bug in range(0,9):
    row={}
    d,k,_=run(["+MODE=directed",f"+BUG={bug}"]); det=int(d["sb_errors"])>0 or int(d["proto_errors"])>0 or d["hang"]=="1"
    row["directed"]={"detected":det,"cov":float(d["cov"])}
    # random: 5 seeds, N=500; also txns-to-first-failure proxy: run N=25,50,100,200 and see first N that detects
    dets=0; first=[]
    for seed in range(1,6):
        d,k,_=run(["+MODE=random","+N=500",f"+SEED={seed}",f"+BUG={bug}"])
        if int(d["sb_errors"])>0 or int(d["proto_errors"])>0 or d["hang"]=="1": dets+=1
        for n in (10,25,50,100,200,500):
            d2,_,_=run(["+MODE=random",f"+N={n}",f"+SEED={seed}",f"+BUG={bug}"])
            if int(d2["sb_errors"])>0 or int(d2["proto_errors"])>0 or d2["hang"]=="1": first.append(n); break
        else: first.append(None)
    row["random"]={"seeds_detected":dets,"of":5,"first_n_per_seed":first}
    res[bug]=row; print(bug,names[bug],row,flush=True)
json.dump({"names":names,"res":res},open("sweep.json","w"),indent=1)
