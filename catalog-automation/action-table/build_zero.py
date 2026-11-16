import json, os, collections
S = "/tmp/claude-0/-home-user-PIM-Monitor/88d0ff9a-ce40-5c9f-9b0c-afec7250b0c6/scratchpad"
L = lambda p: json.load(open(os.path.join(S, p)))
ents = L("seed/entities.json")
PM = {"ControlPlane": "Control", "ManagementPlane": "Management", "UserAccess": "Data"}
PR = {"Control": 3, "Management": 2, "Data": 1}
LR = {"Privileged": 3, "Specialized": 2, "Enterprise": 1}
eo = {}
for t in L("dl-community/Classification_AadResources.json"):
    for d in t["TierLevelDefinition"]:
        for a in d.get("RoleDefinitionActions", []):
            k = a.lower()
            ent = eo.setdefault(k, {"tier": t["EAMTierLevelName"], "service": d["Service"], "services": []})
            if d["Service"] not in ent["services"]:
                ent["services"].append(d["Service"])
v2 = {}
for p in "ABC":
    for it in L(f"seed/v2/results/pass-{p}.json"):
        v2.setdefault(it["action"].lower(), {})[p] = it
maj = lambda xs: collections.Counter(xs).most_common(1)[0][0]

out_e, flat = [], []
for e in ents:
    acts = []
    for a in e["actions"]:
        k = a["action"].lower()
        prev = {"plane": a["proposedPlane"], "levelFloor": a["proposedLevelFloor"]}
        o = dict(action=a["action"], description=a["description"], msPrivileged=a["msPrivileged"])
        if k in eo:
            x = eo[k]
            plane = PM[x["tier"]]; lvl = a["proposedLevelFloor"]; src = "entraops"
            svc = x["service"]; passes = []
            lu = len({p["levelFloor"] for p in a["passes"]}) <= 1
            if a["msPrivileged"] is True:
                if plane != "Control": src = "microsoft-flag"
                plane = "Control"; lvl = "Privileged"
            o["entraOpsServices"] = x["services"]
        else:
            r = v2[k]; assert set(r) == set("ABC"), k
            assert len({(r[p]["plane"], r[p]["levelFloor"]) for p in "ABC"}) == 1, k
            plane = maj([r[p]["plane"] for p in "ABC"]); lvl = maj([r[p]["levelFloor"] for p in "ABC"])
            svc = maj([r[p]["service"] for p in "ABC"]); src = "v2-assessment"
            passes = [{"plane": r[p]["plane"], "levelFloor": r[p]["levelFloor"]} for p in "ABC"]
            lu = True
            o["reason"] = r["A"]["reason"]
            if a["msPrivileged"] is True:
                plane = "Control"; lvl = "Privileged"
        o.update(proposedPlane=plane, proposedLevelFloor=lvl, service=svc, source=src,
                 entraOpsTier=a["entraOpsTier"], passes=passes, usedByRoles=a["usedByRoles"],
                 levelUnanimous=lu, previousProposal=prev)
        acts.append(o)
    pa = max(acts, key=lambda x: PR[x["proposedPlane"]])
    la = max(acts, key=lambda x: LR[x["proposedLevelFloor"]])
    svcs = []
    for x in acts:
        if x["service"] not in svcs: svcs.append(x["service"])
    short = lambda n: n.split("/", 2)[-1] if n.count("/") >= 2 else n
    reason = (f"Nulpunt EntraOps (Thomas Naunheim). Services: {', '.join(svcs)}. "
              f"Plane bepaald door {pa['action']}; niveau bepaald door {la['action']}.")
    flags = [x for x in acts if x["source"] == "microsoft-flag"]
    v2a = [x for x in acts if x["source"] == "v2-assessment"]
    if flags: reason += " Microsoft-vlag gaat voor bij: " + ", ".join(x["action"] for x in flags) + "."
    if v2a: reason += " Opnieuw beoordeeld met methode v2: " + ", ".join(x["action"] for x in v2a) + "."
    reasons = []
    if v2a: reasons.append("nieuw beoordeeld (geen EntraOps)")
    if flags: reasons.append("Microsoft-vlag wijkt af van EntraOps")
    if any(not x["levelUnanimous"] for x in acts): reasons.append("niveau: sessies oneens")
    ne = dict(docId=e["docId"], entity=e["entity"], namespace=e["namespace"], flagged=bool(reasons),
              reasons=reasons, proposal=dict(plane=pa["proposedPlane"], levelFloor=la["proposedLevelFloor"], reason=reason),
              actions=acts)
    out_e.append(ne)
    for x in acts: flat.append(dict(entity=e["entity"], docId=e["docId"], **x))

V = os.path.join(S, "seed/v2")
json.dump(out_e, open(f"{V}/entities-zero.json", "w"), ensure_ascii=False, indent=1)
json.dump(flat, open(f"{V}/actions-zero.json", "w"), ensure_ascii=False, indent=1)
ro = [dict(RoleDefinitionId=r["RoleDefinitionId"], RoleDefinitionName=r["RoleDefinitionName"],
           plane=PM[r["EAMTierLevelName"]], Service=r["Service"], Justification=r["Justification"])
      for r in L("dl-community/Classification_RoleDefinitionOverwrites.json")]
json.dump(ro, open(f"{V}/role-overrides.json", "w"), ensure_ascii=False, indent=1)
for ne in out_e:
    json.dump(ne, open(f"{V}/db-chunks/{ne['docId']}.json", "w"), ensure_ascii=False)

C = collections.Counter
lines = [f"Entities: {len(out_e)}  Actions: {len(flat)}",
         "Actions per source: " + str(dict(C(a["source"] for a in flat))),
         "Entities flagged: " + str(sum(e["flagged"] for e in out_e)),
         "Entities per reason: " + str(dict(C(r for e in out_e for r in e["reasons"]))),
         "Entity plane distribution: " + str(dict(C(e["proposal"]["plane"] for e in out_e))),
         "Entity level distribution: " + str(dict(C(e["proposal"]["levelFloor"] for e in out_e))),
         "Action plane distribution: " + str(dict(C(a["proposedPlane"] for a in flat))),
         "Actions with plane changed vs previousProposal: " + str(sum(a["proposedPlane"] != a["previousProposal"]["plane"] for a in flat)),
         "Actions with level changed vs previousProposal: " + str(sum(a["proposedLevelFloor"] != a["previousProposal"]["levelFloor"] for a in flat))]
open(f"{V}/summary.txt", "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
