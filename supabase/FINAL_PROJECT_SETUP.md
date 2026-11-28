# Elite FF Tournaments — Final Setup Checklist

## Player registration and slots
1. Run the updated `individual_tournament_join.sql` in Supabase SQL Editor. It keeps individual wallet payment and slot selection, and now also blocks registration after the match starts, for closed tournaments, and for negative entry fees.
2. Run `admin_entry_fee_ledger.sql` once. It enables secure read-only access for the player's own wallet transactions and the admin's entry-fee ledger.

## Results and room security
If these migrations have not already been run in this Supabase project, run them in this order:
1. `leaderboard_winnings.sql`
2. `player_match_results.sql`
3. `prize_wallet_payout.sql`
4. `secure_room_details_confirmed_players.sql`

## Notifications
The Firebase web configuration and VAPID public key are already present in the player app and messaging service worker. Push notifications still require the Supabase Edge Function `send-notification` to be deployed and the `FIREBASE_SERVICE_ACCOUNT` secret to be configured. Follow `NOTIFICATIONS_SETUP.md`.

## Real-player verification
Do not use real deposits or withdrawals for testing. Remaining live verification is limited to real player sign-in, individual slot payments, full BR squad / CS match confirmation, room release notification, and match-result prize credit.
