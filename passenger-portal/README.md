# BUSNEX Passenger Portal (private development)

This portal is intentionally separate from the existing Counter Portal. It is not linked from `index.html` and must not be merged into `main` until the owner approves publication.

## Current implementation
- Standalone passenger-facing page: `/passenger.html`
- Search form for origin, destination and journey date
- Trip result cards, seat picker, passenger details and booking status lookup UI
- Manual payment details:
  - bKash Payment: `01303196779`
  - bKash / Nagad / Rocket Send Money: `01722343216`
- Transaction ID submission UI and explicit pending-verification messaging
- Bangla QR placeholder (awaiting the QR image)

## Important: backend is not connected yet
The browser calls the planned Edge Function endpoint:

`POST https://ikjjmiddgpruufxtyqmd.supabase.co/functions/v1/passenger-portal`

Supported action contract:
- `search_trips`: `{ from, to, date }`
- `get_trip_details`: `{ trip_id }`
- `create_booking`: `{ trip_id, seat_numbers, passenger_name, passenger_phone, passenger_gender, boarding_point_id, dropping_point_id }`
- `submit_payment`: `{ booking_reference, payment_method, transaction_id }`
- `track_booking`: `{ reference }`

The endpoint does not exist yet. The page is fail-closed: it does not directly query protected BUSNEX tables, does not expose service-role credentials, and does not create or confirm tickets in the browser. Live searches/bookings will show a safe connection-unavailable message until the Edge Function and database migration are implemented and tested.

## Required server-side workflow
1. Public search returns only active, scheduled, non-archived trips, public company/coach labels, fare, journey time, boarding points and aggregated seat availability. Never return passenger data or ticket details.
2. Booking creation validates trip/company status, validates all seat numbers and route stops, locks selected seats in a single transaction, rejects duplicates/sold/blocked/held/reserved seats, and creates a passenger-specific pending booking with a short expiry.
3. Payment submission stores payment method, transaction ID, submitted timestamp and a pending-review status. Unique/idempotency protections prevent repeated submissions from generating multiple bookings or payments.
4. Only an authenticated, authorized company manager or designated company staff member can approve/reject payment. Approval must be atomic: verify the booking has not expired, verify all seats are still owned by that booking, create sold ticket rows and mark seats sold exactly once. Rejection/expiry releases only the seats held by that booking.
5. Public tracking requires a high-entropy booking reference plus phone verification or equivalent anti-enumeration control. Never expose full passenger phone or transaction details in public search.
6. Rate-limit search, booking, payment and tracking; add CAPTCHA/abuse protection before public launch; log audit events.
7. Use Edge Functions with server-side secrets for privileged database work. Never put Supabase service-role keys in this page. Do not grant public table SELECT/INSERT/UPDATE on `tickets`, `ticket_reservations`, `trip_seats`, or passenger records.

## Existing BUSNEX constraints discovered
- `ticket_reservations.status` only supports `active / confirmed / expired / cancelled`.
- `tickets.status` only supports `sold / cancelled`.
- Existing `busnex_create_reservation`, `busnex_hold_seat`, and `busnex_sell_ticket` require an authenticated BUSNEX staff role/counter and are not suitable for anonymous passengers.
- Therefore passenger pending-payment records must be separate from the existing counter reservation and ticket lifecycle until an explicit, tested staff approval step converts a pending booking to a sold ticket.
- Existing Counter Portal files and production database functions have not been changed by this branch work.

## Before publishing
- Implement and review the isolated passenger schema + Edge Function.
- Add a manager-only payment review screen (preferably in a separate passenger admin page or an approved Counter Portal feature change).
- Add QR image after owner supplies it.
- Test double-booking races, expiry, duplicate Transaction IDs, wrong-company approval, payment rejection, ticket creation, SMS and counter inventory synchronization.
- Verify preview on desktop and mobile, then request explicit owner approval before merging to `main`.
