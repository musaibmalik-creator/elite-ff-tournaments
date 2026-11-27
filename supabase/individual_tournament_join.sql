-- Run in Supabase SQL Editor. Existing registrations are not deleted.
BEGIN;
ALTER TABLE public.teams ALTER COLUMN captain_id DROP NOT NULL;

CREATE OR REPLACE FUNCTION public.join_tournament_with_wallet(p_tournament_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=public,pg_temp AS $$
DECLARE
 u uuid:=auth.uid(); t public.tournaments%ROWTYPE; pr public.profiles%ROWTYPE;
 bal numeric; cap integer; lim integer; n integer; tc integer;
 tid uuid; tname text; pid uuid; eid uuid; slotno integer; mode text; cs boolean;
BEGIN
 IF u IS NULL THEN RAISE EXCEPTION 'Please login first.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtext('elite_ff_join'),hashtext(p_tournament_id::text));
 SELECT * INTO t FROM public.tournaments WHERE id=p_tournament_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Tournament not found.'; END IF;
 IF lower(coalesce(t.status,'')) IN ('closed','completed','cancelled','full') THEN RAISE EXCEPTION 'Tournament is not accepting players.'; END IF;
 IF EXISTS(SELECT 1 FROM public.players WHERE tournament_id=p_tournament_id AND user_id=u) THEN RAISE EXCEPTION 'You have already joined this tournament.'; END IF;
 SELECT * INTO pr FROM public.profiles WHERE id=u;
 IF NOT FOUND OR coalesce(trim(pr.ff_name),'')='' OR coalesce(trim(pr.ff_uid),'')='' THEN RAISE EXCEPTION 'Save your Free Fire Name and UID in Profile first.'; END IF;
 mode:=lower(coalesce(t.sport,''));
 cap:=CASE mode WHEN 'cs_1v1' THEN 1 WHEN 'cs_2v2' THEN 2 WHEN 'cs_4v4' THEN 4 WHEN 'br_solo' THEN 1 WHEN 'br_duo' THEN 2 WHEN 'br_squad' THEN 4 WHEN 'lone_wolf' THEN 1 ELSE 0 END;
 IF cap=0 THEN RAISE EXCEPTION 'Unsupported tournament mode.'; END IF;
 cs:=mode IN ('cs_1v1','cs_2v2','cs_4v4');
 lim:=CASE WHEN cs OR mode='lone_wolf' THEN 2 ELSE greatest(coalesce(t.max_teams,0),0) END;
 IF lim<1 THEN RAISE EXCEPTION 'No slots configured for this tournament.'; END IF;
 SELECT balance INTO bal FROM public.wallets WHERE user_id=u FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Wallet not found. Please contact support.'; END IF;
 IF coalesce(bal,0)<coalesce(t.entry_fee,0) THEN RAISE EXCEPTION 'Insufficient wallet balance. Deposit first.'; END IF;

 tid:=NULL; tname:=NULL;
 IF cs THEN
   FOR tname IN SELECT unnest(ARRAY['Team A','Team B']) LOOP
     SELECT tm.id INTO tid FROM public.teams tm
     WHERE tm.tournament_id=p_tournament_id AND tm.name=tname
       AND EXISTS(SELECT 1 FROM public.players x WHERE x.team_id=tm.id AND x.user_id IS NOT NULL)
       AND (SELECT count(*) FROM public.players x WHERE x.team_id=tm.id AND x.user_id IS NOT NULL)<cap
     ORDER BY tm.created_at LIMIT 1;
     IF tid IS NOT NULL THEN EXIT; END IF;
   END LOOP;
   IF tid IS NULL THEN
     SELECT count(*) INTO tc FROM public.teams tm WHERE tm.tournament_id=p_tournament_id
       AND tm.name IN ('Team A','Team B')
       AND EXISTS(SELECT 1 FROM public.players x WHERE x.team_id=tm.id AND x.user_id IS NOT NULL);
     IF tc>=2 THEN RAISE EXCEPTION 'All CS slots are full.'; END IF;
     tname:=CASE WHEN tc=0 THEN 'Team A' ELSE 'Team B' END;
   END IF;
 ELSE
   SELECT tm.id,tm.name INTO tid,tname FROM public.teams tm
   WHERE tm.tournament_id=p_tournament_id
     AND EXISTS(SELECT 1 FROM public.players x WHERE x.team_id=tm.id AND x.user_id IS NOT NULL)
     AND (SELECT count(*) FROM public.players x WHERE x.team_id=tm.id AND x.user_id IS NOT NULL)<cap
   ORDER BY tm.created_at LIMIT 1;
   IF tid IS NULL THEN
     SELECT count(*) INTO tc FROM public.teams tm WHERE tm.tournament_id=p_tournament_id
       AND EXISTS(SELECT 1 FROM public.players x WHERE x.team_id=tm.id AND x.user_id IS NOT NULL);
     IF tc>=lim THEN RAISE EXCEPTION 'All tournament slots are full.'; END IF;
     tname:=CASE WHEN mode IN ('br_solo','lone_wolf') THEN 'Slot '||(tc+1) ELSE 'Team '||(tc+1) END;
   END IF;
 END IF;

 IF tid IS NULL THEN
   INSERT INTO public.teams(tournament_id,captain_id,name) VALUES(p_tournament_id,NULL,tname) RETURNING id INTO tid;
   INSERT INTO public.tournament_entries(tournament_id,team_id,user_id,status) VALUES(p_tournament_id,tid,u,'pending') RETURNING id INTO eid;
 ELSE
   SELECT id INTO eid FROM public.tournament_entries WHERE tournament_id=p_tournament_id AND team_id=tid ORDER BY created_at LIMIT 1;
   IF eid IS NULL THEN
     INSERT INTO public.tournament_entries(tournament_id,team_id,user_id,status) VALUES(p_tournament_id,tid,u,'pending') RETURNING id INTO eid;
   END IF;
 END IF;

 SELECT count(*)+1 INTO slotno FROM public.players WHERE team_id=tid AND user_id IS NOT NULL;
 UPDATE public.wallets SET balance=balance-coalesce(t.entry_fee,0),updated_at=now() WHERE user_id=u;
 INSERT INTO public.players(team_id,name,team_name,tournament_id,uid,status,user_id,slot_number)
 VALUES(tid,pr.ff_name,tname,p_tournament_id,pr.ff_uid,'registered',u,slotno) RETURNING id INTO pid;
 INSERT INTO public.wallet_transactions(user_id,amount,type,status,reference_id)
 VALUES(u,-coalesce(t.entry_fee,0),'tournament_entry','completed',pid);
 SELECT count(*) INTO n FROM public.players WHERE team_id=tid AND user_id IS NOT NULL;
 IF n>=cap THEN
   UPDATE public.tournament_entries SET status='confirmed' WHERE id=eid;
   UPDATE public.players SET status='confirmed' WHERE team_id=tid;
 END IF;
 RETURN jsonb_build_object('success',true,'team_id',tid,'team_name',tname,'player_id',pid,'slot_number',slotno,'team_players',n,'team_capacity',cap,'team_status',CASE WHEN n>=cap THEN 'confirmed' ELSE 'pending' END,'charged',coalesce(t.entry_fee,0));
END; $$;

REVOKE ALL ON FUNCTION public.join_tournament_with_wallet(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.join_tournament_with_wallet(uuid) TO authenticated;
COMMIT;
