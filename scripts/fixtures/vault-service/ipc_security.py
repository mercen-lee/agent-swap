#!/usr/bin/env python3
import base64, hashlib, json, os, pathlib, plistlib, secrets, shutil, signal, subprocess, sys, tempfile, time
from fixture_cleanup import cleanup_fixture, stop_owned_processes

ROOT=pathlib.Path(__file__).resolve().parents[3]
SOURCE=pathlib.Path(__file__).with_name('IPCSecurityFixture.m')
PARENT='net.mercen.agentswap.xpcproof.parent'
HELPER='net.mercen.agentswap.xpcproof.helper'
def run(args, **kw):
    p=subprocess.run([str(a) for a in args],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60,**kw)
    if p.returncode:
        raise RuntimeError(pathlib.Path(str(args[0])).name+': '+p.stderr.decode(errors='replace')[-2500:])
    return p.stdout

def main(*, reconnect_only=False):
    started=time.monotonic(); before=run(['/usr/bin/security','list-keychains','-d','user'])
    default_before=run(['/usr/bin/security','default-keychain','-d','user'])
    folder=pathlib.Path(tempfile.mkdtemp(prefix='agentswap-xpc-auth-proof-',dir='/tmp')); os.chmod(folder,0o700)
    signing=folder/'release-signing'; keychains=[]
    try:
        run(['/usr/bin/xcrun','swiftc','-suppress-warnings',ROOT/'scripts/release-signing.swift','-o',signing])
        certs=[]
        for label in ('a','b'):
            d=folder/label; d.mkdir(mode=0o700)
            (d/'openssl.cnf').write_text('[req]\ndistinguished_name=dn\nx509_extensions=extensions\nprompt=no\n[dn]\nCN=AgentSwap Release Signing\nO=AgentSwap Synthetic Fixture\n[extensions]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n')
            run(['/usr/bin/openssl','req','-new','-newkey','rsa:2048','-nodes','-x509','-days','1','-sha256','-config',d/'openssl.cnf','-keyout',d/'private.pem','-out',d/'certificate.pem'])
            der=d/'certificate.cer'; run(['/usr/bin/openssl','x509','-in',d/'certificate.pem','-outform','DER','-out',der])
            password=secrets.token_hex(32)
            run(['/usr/bin/openssl','pkcs12','-export','-inkey',d/'private.pem','-in',d/'certificate.pem','-out',d/'identity.p12','-passout','stdin'],input=(password+'\n').encode())
            kc=d/'synthetic.keychain-db'
            keychains.append(kc)  # Track partial creation before invoking Security.
            run([signing,'create-keychain',kc,der],input=json.dumps({'p12':base64.b64encode((d/'identity.p12').read_bytes()).decode(),'password':password}).encode())
            certs.append((hashlib.sha1(der.read_bytes()).hexdigest().upper(),kc))
        events=folder/'events.jsonl'
        parent_req=f'identifier "{PARENT}" and certificate leaf = H"{certs[0][0]}"'
        def compile(path,helper,version,service_auth=False):
            run(['/usr/bin/xcrun','clang','-fobjc-arc','-fblocks','-mmacosx-version-min=14.0','-framework','Foundation','-framework','Security','-DHELPER='+str(int(helper)),'-DPARENT_VERSION='+str(version),'-DBOOTSTRAP_AUTH='+str(int(service_auth)),'-DPARENT_REQ=@'+json.dumps(parent_req),'-DEVENT_PATH=@'+json.dumps(str(events)),SOURCE,'-o',path])
        def sign(path,identifier,idx):
            fp,kc=certs[idx]
            run(['/usr/bin/codesign','--force','--options','runtime','--sign',fp,'--keychain',kc,'--identifier',identifier,'--requirements',f'=designated => identifier "{identifier}" and certificate leaf = H"{fp}"','--timestamp=none',path])
        helper_bundle=folder/'immutable-helper.xpc'; he=helper_bundle/'Contents/MacOS/ProofHelper'; he.parent.mkdir(parents=True)
        (helper_bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':HELPER,'CFBundleExecutable':'ProofHelper','CFBundleVersion':'1','CFBundlePackageType':'XPC!','XPCService':{'ServiceType':'Application','RunLoopType':'dispatch_main'}}))
        compile(he,True,0); sign(helper_bundle,HELPER,0)
        detail=subprocess.run(['/usr/bin/codesign','-dv','--verbose=4',str(helper_bundle)],capture_output=True,check=True).stderr.decode()
        hhash=next(x.split('=',1)[1] for x in detail.splitlines() if x.startswith('CDHash='))
        helper_req=f'identifier "{HELPER}" and certificate leaf = H"{certs[0][0]}" and cdhash H"{hhash}"'
        cases=[('parent_a',0,1),('parent_b',0,2),('wrong_certificate',1,3),('ad_hoc',None,4),('wrong_helper_requirement',0,5),('truly_unsigned',None,6),('service_auth_parent_a',0,7),('service_auth_parent_b',0,8),('service_auth_wrong_certificate',1,9),('service_auth_ad_hoc',None,10),('bad_server_certificate',0,11),('bad_server_cdhash',0,12),('bad_reply_nonce',0,13),('bad_reply_version',0,14),('endpoint_swap_wrong_certificate',0,15),('endpoint_swap_wrong_cdhash',0,16)]
        protected_bundle=folder/'service-auth-helper.xpc'; shutil.copytree(helper_bundle,protected_bundle)
        compile(protected_bundle/'Contents/MacOS/ProofHelper',True,0,True); sign(protected_bundle,HELPER,0)
        protected_detail=subprocess.run(['/usr/bin/codesign','-dv','--verbose=4',str(protected_bundle)],capture_output=True,check=True).stderr.decode()
        protected_hash=next(x.split('=',1)[1] for x in protected_detail.splitlines() if x.startswith('CDHash='))
        protected_req=helper_req.replace(hhash,protected_hash)
        variants={}
        for label in ('bad_server_certificate','bad_server_cdhash','bad_reply_nonce','bad_reply_version'):
            v=folder/(label+'-helper.xpc'); shutil.copytree(protected_bundle,v)
            info=plistlib.loads((v/'Contents/Info.plist').read_bytes())
            if label=='bad_server_cdhash': info['CFBundleVersion']='2'
            if label.startswith('bad_reply_'): info['XPCProofReplyMode']=label.replace('bad_reply_','bad_')
            (v/'Contents/Info.plist').write_bytes(plistlib.dumps(info)); sign(v,HELPER,1 if label=='bad_server_certificate' else 0)
            detail=subprocess.run(['/usr/bin/codesign','-dv','--verbose=4',str(v)],capture_output=True,check=True).stderr.decode()
            vh=next(x.split('=',1)[1] for x in detail.splitlines() if x.startswith('CDHash='))
            assert vh!=protected_hash
            variants[label]=(v,protected_req.replace(protected_hash,vh) if label.startswith('bad_reply_') else protected_req)
        swap_variants={}
        for label in ('endpoint_swap_wrong_certificate','endpoint_swap_wrong_cdhash'):
            v=folder/(label+'-replacement.xpc'); shutil.copytree(helper_bundle,v)
            if label.endswith('cdhash'):
                info=plistlib.loads((v/'Contents/Info.plist').read_bytes()); info['CFBundleVersion']='99'; (v/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            sign(v,HELPER,1 if label.endswith('certificate') else 0)
            swap_variants[label]=v
        if reconnect_only: cases=[c for c in cases if c[0] in ('parent_a','parent_b') or c[0].startswith('endpoint_swap_')]
        results=[]; hashes=[]
        for label,idx,version in cases:
            app=folder/(label+'.app'); exe=app/'Contents/MacOS/ProofParent'; exe.parent.mkdir(parents=True)
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':PARENT,'CFBundleExecutable':'ProofParent','CFBundleVersion':str(version),'CFBundlePackageType':'APPL','LSUIElement':True}))
            xpc=app/'Contents/XPCServices'; xpc.mkdir()
            chosen=variants[label][0] if label in variants else protected_bundle if label.startswith('service_auth_') else helper_bundle
            shutil.copytree(chosen,xpc/(HELPER+'.xpc'))
            compile(exe,False,version)
            if idx is not None: sign(app,PARENT,idx)
            elif label in ('ad_hoc','service_auth_ad_hoc'): run(['/usr/bin/codesign','--force','--sign','-','--identifier',PARENT,app])
            else: run(['/usr/bin/codesign','--remove-signature',exe])
            if idx is not None:
                p=subprocess.run(['/usr/bin/codesign','-dv','--verbose=4',str(app)],capture_output=True,check=True)
                hashes.append(next(x.split('=',1)[1] for x in p.stderr.decode().splitlines() if x.startswith('CDHash=')))
            requirement=protected_req if label.startswith('service_auth_') else helper_req
            if label in variants: requirement=variants[label][1]
            if label=='wrong_helper_requirement': requirement=requirement.replace(certs[0][0],certs[1][0])
            if label=='truly_unsigned':
                p=subprocess.Popen([str(exe),requirement,label],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                out,err=p.communicate(timeout=10)
                if p.returncode < 0:
                    result={'label':label,'pid':p.pid,'echo':False,'counter':0,'outcome':'kernel_rejected','returncode':p.returncode,'unsigned_rejection_layer':'kernel'}
                elif p.returncode == 0:
                    result=json.loads(out)
                    result['unsigned_rejection_layer']='xpc'
                else:
                    raise RuntimeError('Unsigned fixture exited without proving kernel or XPC rejection')
            elif label.startswith('endpoint_swap_'):
                p=subprocess.Popen([str(exe),requirement,label],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                deadline=time.monotonic()+10; old_helper=None
                while time.monotonic()<deadline:
                    ev=[json.loads(x) for x in events.read_text().splitlines()] if events.exists() else []
                    if any(e['peer']==p.pid and e['event']=='parent_ready_for_swap' for e in ev):
                        old_helper=next(e['helper'] for e in ev if e['peer']==p.pid and e['event']=='authenticated_handshake'); break
                    if p.poll() is not None: raise RuntimeError('Swap parent exited before private authentication')
                    time.sleep(.01)
                assert old_helper is not None, 'Swap handshake did not complete'
                comm=run(['/bin/ps','-p',str(old_helper),'-o','comm=']).decode().strip()
                assert pathlib.Path(comm).resolve()==(xpc/(HELPER+'.xpc')/'Contents/MacOS/ProofHelper').resolve()
                os.kill(old_helper,signal.SIGKILL)
                for unused in range(200):
                    check=subprocess.run(['/bin/ps','-p',str(old_helper),'-o','stat='],capture_output=True)
                    if check.returncode or check.stdout.strip().startswith(b'Z'): break
                    time.sleep(.01)
                assert check.returncode or check.stdout.strip().startswith(b'Z'), 'Trusted synthetic helper did not exit'
                installed=xpc/(HELPER+'.xpc'); shutil.rmtree(installed); shutil.copytree(swap_variants[label],installed)
                # Keep the synthetic host container valid so launchd can actually
                # launch the wrong nested helper. Its credential channel stays
                # bound to the already-dead original anonymous endpoint.
                sign(app,PARENT,0)
                pathlib.Path(str(events)+'.gate-'+label).touch(mode=0o600)
                out,err=p.communicate(timeout=25)
                assert p.returncode==0, err.decode(errors='replace')
                result=json.loads(out); result['terminated_trusted_helper_pid']=old_helper
            else: result=json.loads(run([exe,requirement,label]))
            results.append(result); print("IPC " + label + ": " + result["outcome"],flush=True)
        # The helper schedules its own bounded synthetic exit after broker call.
        time.sleep(7)
        observed=[json.loads(s) for s in events.read_text().splitlines()] if events.exists() else []
        for r in results:
            own=[e for e in observed if e['peer']==r['pid']]
            r['exported_mutations']=sum(e['event']=='mutation' for e in own)
            r['anonymous_delegate_calls']=sum(e['event']=='anonymous_delegate' for e in own)
            r['ping_calls']=sum(e['event']=='authenticated_handshake' for e in own)
            r['synthetic_vault_calls']=sum(e['event']=='synthetic_vault' for e in own)
        assert hashes[0]!=hashes[1], 'A/B did not change cdhash'
        for r in results:
            if r['label'] in ('parent_a','parent_b','service_auth_parent_a','service_auth_parent_b'):
                assert r['echo'] and r['counter']==1 and r['exported_mutations']==1 and r['authenticated_handshake'] and r['helper_same_uid'], r
            else: assert not r['echo'] and r['exported_mutations']==0, r
        for r in results:
            label=r['label']
            if label in ('wrong_certificate','ad_hoc'): assert r['anonymous_delegate_calls']==0,r
            if label=='wrong_helper_requirement': assert r['outcome']=='bootstrap_rejected',r
            if label=='truly_unsigned':
                assert r['outcome'] in ('kernel_rejected','anonymous_rejected','bootstrap_rejected'),r
                assert r['unsigned_rejection_layer'] in ('kernel','xpc'),r
                assert r['anonymous_delegate_calls']==0 and r['ping_calls']==0 and r['synthetic_vault_calls']==0,r
            if label in ('service_auth_wrong_certificate','service_auth_ad_hoc'): assert r['outcome']=='service_rejected' and r['ping_calls']==0,r
            if label.startswith('bad_server_'): assert r['outcome']=='service_rejected' and r['ping_calls']==1 and r['synthetic_vault_calls']==0,r
            if label.startswith('bad_reply_'): assert r['outcome']=='handshake_rejected' and r['ping_calls']==1 and r['synthetic_vault_calls']==0,r
            if label.startswith(('service_auth_','bad_server_','bad_reply_')): assert r['anonymous_delegate_calls']==0,r
            if label.startswith('endpoint_swap_'):
                assert r['outcome'] in ('anonymous_rejected','private_execute_timeout') and r['authenticated_handshake'] and r['exported_mutations']==0 and r['synthetic_vault_calls']==0,r
                own=[e for e in observed if e['peer']==r['pid']]
                assert any(e['event']=='private_invalidated' for e in own),r
                new_helpers={e['helper'] for e in own if e['event']=='broker' and e['helper']!=r['terminated_trusted_helper_pid']}
                assert new_helpers, ('Wrong replacement helper was not actually launched',r,own)
                assert not any(e['helper'] in new_helpers and e['event'] in ('authenticated_handshake','mutation','synthetic_vault','anonymous_delegate') for e in observed),r
                assert max(i for i,e in enumerate(observed) if e['peer']==r['pid'] and e['helper'] in new_helpers and e['event']=='broker') < next(i for i,e in enumerate(observed) if e['peer']==r['pid'] and e['event']=='private_execute_attempt'),r
                r['replacement_helper_pids']=sorted(new_helpers)
                r['private_channel_terminal']=True
                r['replacement_payload_calls']=0
                r['replacement_vault_calls']=0
        report={'passed':True,'elapsed_seconds':round(time.monotonic()-started,2),'a_b_different_cdhash':True,'helper_requirement_includes_cdhash':True,'results':results,'events':observed}
        print(json.dumps({'suite':'IPC security','passed':True,'cases':len(results),'elapsed_seconds':report['elapsed_seconds']}),flush=True)
        return report
    finally:
        def delete_owned_keychain(keychain):
            if keychain.exists():
                if not signing.is_file(): raise RuntimeError('Synthetic signing helper is unavailable')
                result=subprocess.run([str(signing),'delete-keychain',str(keychain)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
                if result.returncode or keychain.exists(): raise RuntimeError('Security did not delete the synthetic Keychain')
        def current_metadata():
            return (run(['/usr/bin/security','list-keychains','-d','user']),
                    run(['/usr/bin/security','default-keychain','-d','user']))
        cleanup_fixture(directory=folder,keychains=keychains,before_metadata=(before,default_before),
                        stop_processes=stop_owned_processes,delete_keychain=delete_owned_keychain,
                        metadata=current_metadata,scope='IPC security')
if __name__ == '__main__':
    main(reconnect_only='--reconnect-only' in sys.argv)
