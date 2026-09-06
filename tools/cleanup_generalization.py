#!/usr/bin/env python3
"""Generalization gate: corrections and list requests with content that appears in no prompt example.
Usage: cleanup_generalization.py [prompt-file]  (defaults to the installed prompt)"""
import sys
from cleanup_common import configuration, request
cfg = configuration()
sysp = open(sys.argv[1]).read() if len(sys.argv)>1 else cfg["system_prompt"]
cfg["system_prompt"] = sysp
def ask(t): return request(cfg,cfg["model"],t)[0]
L=lambda o:o.lower(); has=lambda o,*w: all(x.lower() in L(o) for x in w); no=lambda o,*w: all(x.lower() not in L(o) for x in w)
bul=lambda o,n: o.count("\n- ")+o.startswith("- ")>=n
C=[
 # novel content: list request + item replacement + later correction
 ("list-replace-1","order pens notebooks and staplers actually not staplers make it markers and deliver it Tuesday or no better Wednesday", lambda o: has(o,"markers","Wednesday") and no(o,"staplers","Tuesday","actually")),
 ("list-replace-2","put together a list out of tomatoes onions and garlic hmm scratch the garlic use ginger instead", lambda o: bul(o,3) and has(o,"ginger") and no(o,"garlic","scratch")),
 ("list-de","mach eine liste mit hammer zange und säge nein keine säge lieber einen bohrer und wir fahren am dienstag oder nein besser am donnerstag", lambda o: has(o,"Bohrer","Donnerstag") and no(o,"Säge","Dienstag","lieber")),
 ("list-fr","fais une liste avec du lait du pain et du beurre non pas de beurre plutôt du fromage", lambda o: has(o,"fromage") and no(o,"beurre")),
 ("list-es","haz una lista con leche pan y mantequilla no mantequilla no mejor queso", lambda o: has(o,"queso") and no(o,"mantequilla")),
 # corrections in prose, novel phrasings
 ("corr-or-no","the demo is on the twelfth or no even better the fifteenth", lambda o: (has(o,"15") or has(o,"fifteenth")) and no(o,"12","twelfth","or no")),
 ("corr-instead","book the hotel in Munich actually Berlin instead", lambda o: has(o,"Berlin") and no(o,"Munich","instead","actually")),
 ("corr-not","send the draft to Priya no not Priya to Tom", lambda o: has(o,"Tom") and no(o,"Priya")),
 ("corr-meant","the price is nine euros sorry I meant nineteen euros", lambda o: (has(o,"19") or has(o,"nineteen")) and no(o,"nine euros","meant","sorry")),
 ("corr-de","wir nehmen den blauen nein ich meine den grünen", lambda o: has(o,"grünen") and no(o,"blauen","ich meine")),
 ("corr-fr","on se voit lundi non plutôt mardi", lambda o: has(o,"mardi") and no(o,"lundi")),
 ("corr-long","the report is due Thursday and I already talked to the finance team about the numbers they want a breakdown by region we should probably use the old template no wait use the new one from last quarter and I will send the draft tonight", lambda o: has(o,"new one") and no(o,"old template","no wait")),
 ("corr-mid-list","three tasks first write the spec second no wait second review the design third ship", lambda o: has(o,"design") and no(o,"no wait") and L(o).count("second")<=1),
 # must NOT be lists or corrections
 ("nolist-request","can you make a list of everything we discussed and send it to me", lambda o: not bul(o,1) and has(o,"make a list")),
 ("nolist-prose","the invoice is for pens notebooks and markers which we sell at the store", lambda o: not bul(o,1) and has(o,"pens")),
 ("nocorr-actually","actually I really liked the movie", lambda o: has(o,"liked the movie")),
 ("nocorr-or","we can meet on Monday or Tuesday whichever works", lambda o: has(o,"Monday") and has(o,"Tuesday")),
 ("nocorr-instead","use butter instead of oil for this recipe", lambda o: has(o,"butter") and has(o,"oil")),
 ("nocorr-not","not the red one the blue one is better", lambda o: has(o,"blue")),
 # code-switch guard
 ("mix-guard","okay let's schedule the call for morgen um zehn", lambda o: has(o,"morgen um") and no(o,"tomorrow")),
 ("mix-guard-2","ich schicke dir den link later today", lambda o: has(o,"later today") and has(o,"schicke")),
]
ask("warm")
f=[]
for n,t,c in C:
    o=ask(t); ok=c(o); f.append(n) if not ok else None
    print(f"{'PASS' if ok else 'FAIL':4} {n:16} {o.replace(chr(10),' / ')[:120]}")
print(f"\n{len(C)-len(f)}/{len(C)}  prompt {len(sysp)} chars"); print("FAILS:",", ".join(f))

if f: raise SystemExit(1)
