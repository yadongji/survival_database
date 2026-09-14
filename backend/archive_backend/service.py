from __future__ import annotations
import hashlib
import hmac
import json
import math
import re
import subprocess
import threading
from pathlib import Path
from .bundle import Bundle

class ArchiveError(ValueError):
    pass

FIELDS = {
    "clear": {"difficulty_id","count","day_key"}, "boss_kill": set(),
    "endless": {"wave","difficulty"},
    "challenge": {"challenge_id","kill_sequence","difficulty_id","day_key"},
    "social_draw": {"pool_id"}, "promotion": {"fragment_id","day_key"},
    "daily_init": {"today"}, "daily_claim": {"today","target_day"},
    "work_upgrade": {"item_id","expected_level"},
    "building_upgrade": {"item_id","expected_level"},
    # No simulated currency/faith grants in the HTTP integration.
    "lottery_draw": {"pool_id","count","request_id"},
    "lottery_exchange": {"pool_id","item_id","request_id"},
    "lottery_read": {"pool_id","revision","read_action","request_id"},
}

def object_maps(value):
    # Lua's empty table encoder produces []; saved archive empty fields are all maps.
    if value == []: return {}
    if isinstance(value,dict): return {k:object_maps(v) for k,v in value.items()}
    if isinstance(value,list): return [object_maps(v) for v in value]
    return value

class ArchiveService:
    slots=threading.BoundedSemaphore(4)
    def __init__(self, application, bundle: Bundle, lua: str):
        self.app,self.bundle,self.lua=application,bundle,lua

    def sync(self):
        return self.app.rpc_client.rpc("archive_sync_config",{
            "p_hash":self.bundle.hash,"p_config":{"configs":self.bundle.configs}})

    def validate(self, command):
        if not isinstance(command,dict): raise ArchiveError("archive_command_invalid")
        kind=command.get("kind")
        if kind not in FIELDS or set(command)-FIELDS[kind]-{"id","kind"}: raise ArchiveError("archive_command_fields_invalid")
        if not isinstance(command.get("id"),str) or not re.fullmatch(r"[A-Za-z0-9_:.-]{8,200}",command["id"]): raise ArchiveError("archive_id_invalid")
        c=dict(command)
        def integer(key,lo,hi):
            v=c.get(key)
            if isinstance(v,bool) or not isinstance(v,(int,float)) or not math.isfinite(v) or int(v)!=v or not lo<=v<=hi: raise ArchiveError("archive_number_invalid:"+key)
            c[key]=int(v)
        if kind=="clear":
            if c.get("count")!=1 or not re.fullmatch(r"n(?:[1-9]|1[0-9]|20)",str(c.get("difficulty_id"))): raise ArchiveError("archive_clear_invalid")
        if kind=="endless":
            integer("wave",1,1000);integer("difficulty",1,20)
        if kind=="challenge":
            definition=self.bundle.tables["archive_challenge_definitions"].get(c.get("challenge_id"))
            if not definition or not definition.get("enabled"): raise ArchiveError("archive_challenge_invalid")
            raw=c.get("difficulty_id")
            if isinstance(raw,str): raw=raw.lower().removeprefix("n")
            if not re.fullmatch(r"(?:[1-9]|1[0-9]|20)",str(raw)): raise ArchiveError("archive_difficulty_invalid")
            try: difficulty=int(raw)
            except (ValueError,TypeError): raise ArchiveError("archive_difficulty_invalid")
            if not max(3,definition["min_difficulty"])<=difficulty<=20: raise ArchiveError("archive_challenge_locked")
            c["difficulty_id"]="n"+str(difficulty);integer("kill_sequence",1,100000)
        if kind=="daily_claim": integer("target_day",0,1000000)
        if kind.startswith("lottery_"):
            if c.get("pool_id") not in self.bundle.tables["lottery_pool_definitions"]: raise ArchiveError("lottery_pool_invalid")
            if not isinstance(c.get("request_id"),str) or not re.fullmatch(r"[A-Za-z0-9_:.-]{1,96}",c["request_id"]): raise ArchiveError("lottery_request_id_invalid")
            if kind=="lottery_draw" and (type(c.get("count")) is not int or c["count"] not in (1,10)): raise ArchiveError("lottery_count_invalid")
            if kind=="lottery_exchange" and c.get("item_id") not in self.bundle.tables["lottery_item_definitions"]: raise ArchiveError("lottery_item_invalid")
            if kind=="lottery_read" and (c.get("read_action") not in ("visit","details","notice") or not isinstance(c.get("revision"),str)): raise ArchiveError("lottery_read_invalid")
        if kind=="faith_cheat": integer("amount",1,1000000000)
        if kind=="social_draw" and c.get("pool_id") not in self.bundle.tables["archive_social_rules"]: raise ArchiveError("archive_pool_invalid")
        if kind=="promotion" and c.get("fragment_id") not in self.bundle.tables["archive_fragment_definitions"]: raise ArchiveError("archive_fragment_invalid")
        if kind=="building_upgrade":
            item=self.bundle.tables["archive_building_items"].get(c.get("item_id"))
            if not item or not item.get("enabled"): raise ArchiveError("archive_building_invalid")
            integer("expected_level",0,item["max_level"]-1)
        if kind=="work_upgrade":
            item=self.bundle.tables["archive_work_items"].get(c.get("item_id"))
            if not item: raise ArchiveError("archive_work_invalid")
            integer("expected_level",0,item["max_level"]-1)
        # A retry across midnight keeps the first database-recorded date, never client date.
        c.pop("today",None);c.pop("day_key",None)
        match=c["id"].split(":",1)[0]
        if kind=="clear": c["id"]=match+":clear"
        if kind=="endless": c["id"]=match+":endless:"+str(c["wave"])
        if kind=="challenge": c["id"]=match+":challenge_kind:"+c["challenge_id"]
        return c

    def settle(self,profile,command,has_pass):
        seed=int.from_bytes(hmac.new(self.app.account_id_pepper.encode(),
            (profile["account_id"]+":"+command["id"]).encode(),hashlib.sha256).digest()[:4],"big")%2147483646+1
        payload={"configs":self.bundle.configs,"profile":profile,"command":command,"has_pass":has_pass,"seed":seed}
        if not self.slots.acquire(timeout=2): raise TimeoutError("archive_workers_busy")
        try:
            completed=subprocess.run([self.lua,"worker.lua"],cwd=self.bundle.directory,
                input=json.dumps(payload,ensure_ascii=False,allow_nan=False).encode(),stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,timeout=10,check=True,creationflags=getattr(subprocess,"CREATE_NO_WINDOW",0))
        finally: self.slots.release()
        result=object_maps(json.loads(completed.stdout))
        if not isinstance(result,dict): raise ArchiveError("archive_worker_invalid")
        return result

    def command(self,payload):
        account=payload.get("account_id")
        if not isinstance(account,str) or not re.fullmatch(r"[0-9]{1,20}",account): raise ArchiveError("account_id_invalid")
        if payload.get("config_hash")!=self.bundle.hash: return {"ok":False,"terminal":True,"error":"archive_config_mismatch","config_hash":self.bundle.hash}
        command=self.validate(payload.get("command"))
        database_id=self.app._database_account_id(account)
        self.app._ensure_gameplay_stats(database_id)
        fingerprint=hashlib.sha256(json.dumps(command,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()
        prepared=self.app.rpc_client.rpc("archive_prepare",{"p_account":database_id,"p_id":command["id"],
            "p_hash":self.bundle.hash,"p_fingerprint":fingerprint,"p_command":command})
        result=self.finish_prepared(database_id,command["id"],prepared)
        return self.app._public_response(result,database_id,account)

    def finish_prepared(self,account,operation_id,prepared):
        for _ in range(4):
            if not prepared.get("ok") or prepared.get("done"): return prepared
            profile,command=prepared["profile"],prepared["command"]
            reducer=self
            version=prepared.get("config_hash",self.bundle.hash)
            if version!=self.bundle.hash:
                if not re.fullmatch(r"[0-9a-f]{64}",version): raise ArchiveError("archive_config_invalid")
                reducer=ArchiveService(self.app,Bundle(self.bundle.directory.parent/version),self.lua)
            result=reducer.settle(profile,command,prepared["has_pass"])
            old=profile["save"]["gameplay_stats"]
            deltas={key:value-old.get(key,0) for key,value in result.get("gameplay_stats",{}).items() if value!=old.get(key,0)}
            archive=result.get("archive",{})
            archive.pop("processed",None) # DB receipts, not ever-growing Lua IDs, own remote deduplication.
            if isinstance(archive.get("online"),dict): archive["online"]["cursors"]={}
            commit_payload={"p_account":account,"p_id":operation_id,
                "p_revision":profile["revision"],"p_archive":archive,"p_deltas":deltas,
                "p_error":None if result.get("ok") else result.get("error","archive_rejected")}
            rpc="archive_commit"
            if command["kind"].startswith("lottery_"):
                rpc="archive_commit_lottery"
                commit_payload.update(p_inventory=result.get("content_inventory",{}),p_response=result.get("response",{}))
            committed=self.app.rpc_client.rpc(rpc,commit_payload)
            if committed.get("error")!="archive_revision_conflict": return committed
            prepared=self.app.rpc_client.rpc("archive_resume",{"p_account":account,"p_id":operation_id})
        return {"ok":False,"error":"archive_busy_retry"}

    def drain_online(self,database_account):
        # Persistent checkpoint outbox survives a Python crash between fishing and archive settlement.
        pending=self.app.rpc_client.rpc("archive_online_pending",{"p_account":database_account,"p_hash":self.bundle.hash})
        for operation in pending:
            prepared=self.app.rpc_client.rpc("archive_resume",{"p_account":database_account,"p_id":operation["id"]})
            result=self.finish_prepared(database_account,operation["id"],prepared)
            if not result.get("ok"): raise ArchiveError("archive_online_pending")

    def profile(self,payload):
        # Called after the existing profile loader initializes a new player.
        value=self.app.profile(payload)
        account=self.app._database_account_id(payload["account_id"])
        self.drain_online(account)
        for pending in self.app.rpc_client.rpc("archive_pending",{"p_account":account}):
            self.finish_prepared(account,pending["id"],self.app.rpc_client.rpc("archive_resume",{"p_account":account,"p_id":pending["id"]}))
        value=self.app.rpc_client.rpc("get_fishing_profile",{"p_account_id":account})
        return self.app._public_response(value,account,payload["account_id"])

    def lottery_snapshot(self,payload):
        if payload.get("config_hash")!=self.bundle.hash:
            return {"ok":False,"terminal":True,"error":"archive_config_mismatch","config_hash":self.bundle.hash}
        profile=self.profile({"account_id":payload.get("account_id")})
        projected=self.settle(profile,{"id":"lottery_snapshot","kind":"lottery_snapshot"},False)
        projected["config_hash"]=self.bundle.hash
        return projected

def install(application,addon_root,lua):
    root=Path(addon_root)
    current=json.loads((root/"server/bundles/current.json").read_text())
    service=ArchiveService(application,Bundle(root/"server/bundles"/current["hash"]),lua)
    service.sync()
    return service
