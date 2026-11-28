# Elite FF Tournaments — Final Setup Checklist

## One-time core database setup
Run **only** `supabase/FINAL_CORE_SETUP.sql` in Supabase Dashboard → SQL Editor → New query → Run.

This single file bundles the core migrations in the correct order:
- Individual wallet-paid slot registration (BR Solo/Duo/Squad, CS 1v1/2v2/4v4, Lone Wolf)
- Registration closing and non-negative entry-fee validation
- Automatic team/match confirmation after all required players have paid
- Player match results and all-time leaderboard
- Automatic, idempotent prize wallet credit
- Room details restricted to admins and confirmed players from 7 minutes before match start
- User notification tables
- Read-only player/admin wallet transaction access for the entry-fee ledger

It intentionally does **not** include deposit or withdrawal migrations and does not modify deposit/withdrawal records or balances.

## Notifications: one external setup remains
Firebase web configuration and the VAPID public key are already present in the player app and messaging service worker. For push delivery, deploy the Supabase Edge Function `send-notification` and add the `FIREBASE_SERVICE_ACCOUNT` secret. Follow `NOTIFICATIONS_SETUP.md`.

## Live testing intentionally left aside
Do not use real deposits or withdrawals for testing. Remaining real-player verification is:
- Player sign-in and profile UID save
- Individual slot payment and slot lock
- BR group confirmation and full CS/Lone Wolf match confirmation
- Room release and push notification receipt
- Match results and automatic prize wallet credit

## Features awaiting external business decisions
- Watch & Earn needs an ad network/app integration and reward rules.
- Referral tracking/rewards need a defined reward amount and eligibility rules. The current Invite Friends button only shares a signup link; it does not promise or credit rewards.
- Instagram/WhatsApp support links can be enabled once the official account/number is supplied.
