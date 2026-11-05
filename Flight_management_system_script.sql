

PRAGMA foreign_keys = ON;

DROP VIEW  IF EXISTS booking_totals;
DROP VIEW  IF EXISTS flight_overview;
DROP TABLE IF EXISTS ticket_extras;
DROP TABLE IF EXISTS tickets;
DROP TABLE IF EXISTS bookings;
DROP TABLE IF EXISTS passengers;
DROP TABLE IF EXISTS flights;
DROP TABLE IF EXISTS routes;
DROP TABLE IF EXISTS aircraft;
DROP TABLE IF EXISTS extras;
DROP TABLE IF EXISTS airports;
DROP TABLE IF EXISTS airlines;

-- Schema --

CREATE TABLE airlines (
    airline_id    INTEGER PRIMARY KEY,
    airline_name  TEXT NOT NULL UNIQUE,
    iata_code     TEXT NOT NULL UNIQUE,
    country       TEXT NOT NULL,                                      -- nominal
    founded_year  INTEGER NOT NULL CHECK (founded_year BETWEEN 1900 AND 2026)   -- interval
);

CREATE TABLE airports (
    airport_id        INTEGER PRIMARY KEY,
    iata_code         TEXT NOT NULL UNIQUE,
    airport_name      TEXT NOT NULL,
    city              TEXT NOT NULL,                                  -- nominal
    country           TEXT NOT NULL,                                  -- nominal
    airport_size      TEXT NOT NULL
                      CHECK (airport_size IN ('National','International','Major Hub')),   -- ordinal
    utc_offset_hours  REAL NOT NULL CHECK (utc_offset_hours BETWEEN -12 AND 14)           -- interval
);

CREATE TABLE aircraft (
    aircraft_id       INTEGER PRIMARY KEY,
    airline_id        INTEGER NOT NULL,
    registration      TEXT NOT NULL UNIQUE,
    model             TEXT NOT NULL,                                  -- nominal
    body_type         TEXT NOT NULL CHECK (body_type IN ('Narrow-body','Wide-body')),
    seat_capacity     INTEGER NOT NULL CHECK (seat_capacity > 0),     -- ratio
    manufacture_year  INTEGER NOT NULL CHECK (manufacture_year BETWEEN 1990 AND 2026),    -- interval
    FOREIGN KEY (airline_id) REFERENCES airlines(airline_id)
);

-- One row per direction: A to B and B to A are separate routes
CREATE TABLE routes (
    route_id               INTEGER PRIMARY KEY,
    origin_airport_id      INTEGER NOT NULL,
    destination_airport_id INTEGER NOT NULL,
    distance_km            INTEGER NOT NULL CHECK (distance_km > 0),  -- ratio
    UNIQUE (origin_airport_id, destination_airport_id),
    CHECK (origin_airport_id <> destination_airport_id),
    FOREIGN KEY (origin_airport_id)      REFERENCES airports(airport_id),
    FOREIGN KEY (destination_airport_id) REFERENCES airports(airport_id)
);

CREATE TABLE flights (
    flight_id           INTEGER PRIMARY KEY,
    flight_number       TEXT NOT NULL,
    route_id            INTEGER NOT NULL,
    aircraft_id         INTEGER NOT NULL,
    departure_datetime  TEXT NOT NULL,                                -- interval, local time
    duration_minutes    INTEGER NOT NULL CHECK (duration_minutes > 0),    -- ratio
    status              TEXT NOT NULL CHECK (status IN ('Scheduled','Arrived','Cancelled')),   -- nominal
    delay_minutes       INTEGER CHECK (delay_minutes >= 0),           -- ratio, 0 = on time
    CHECK (status = 'Arrived' OR delay_minutes IS NULL),
    FOREIGN KEY (route_id)    REFERENCES routes(route_id),
    FOREIGN KEY (aircraft_id) REFERENCES aircraft(aircraft_id)
);

-- No passport numbers, addresses or card details are stored 
CREATE TABLE passengers (
    passenger_id   INTEGER PRIMARY KEY,
    first_name     TEXT NOT NULL,
    last_name      TEXT NOT NULL,
    gender         TEXT NOT NULL CHECK (gender IN ('Male','Female','Other')),   -- nominal
    date_of_birth  TEXT NOT NULL,                                     -- interval
    nationality    TEXT NOT NULL,                                     -- nominal
    loyalty_tier   TEXT NOT NULL
                   CHECK (loyalty_tier IN ('Standard','Silver','Gold','Platinum')),   -- ordinal
    email          TEXT NOT NULL UNIQUE
);

-- A booking is one purchase by one passenger and can cover a party and a return journey
CREATE TABLE bookings (
    booking_id         INTEGER PRIMARY KEY,
    booking_reference  TEXT NOT NULL UNIQUE,
    booker_id          INTEGER NOT NULL,
    booking_date       TEXT NOT NULL,                                 -- interval
    booking_channel    TEXT NOT NULL
                       CHECK (booking_channel IN ('Website','Mobile App','Travel Agent','Call Centre')),
    payment_method     TEXT NOT NULL
                       CHECK (payment_method IN ('Credit Card','Debit Card','PayPal','Digital Wallet','Bank Transfer')),
    trip_type          TEXT NOT NULL CHECK (trip_type IN ('One-way','Round-trip')),
    FOREIGN KEY (booker_id) REFERENCES passengers(passenger_id)
);

-- Compound key: a passenger holds at most one ticket per flight (many-to-many link).
CREATE TABLE tickets (
    flight_id           INTEGER NOT NULL,
    passenger_id        INTEGER NOT NULL,
    booking_id          INTEGER NOT NULL,
    seat_class          TEXT NOT NULL
                        CHECK (seat_class IN ('Economy','Premium Economy','Business','First')),   -- ordinal
    fare_paid           REAL NOT NULL CHECK (fare_paid > 0),          -- ratio
    checked_bags        INTEGER NOT NULL CHECK (checked_bags BETWEEN 0 AND 5),   -- ratio
    meal_preference     TEXT NOT NULL
                        CHECK (meal_preference IN ('Standard','Vegetarian','Vegan','Halal','Kosher','Gluten-free')),
    satisfaction_score  INTEGER CHECK (satisfaction_score BETWEEN 1 AND 5),   -- ordinal, NULL if no reply
    PRIMARY KEY (flight_id, passenger_id),
    FOREIGN KEY (flight_id)    REFERENCES flights(flight_id),
    FOREIGN KEY (passenger_id) REFERENCES passengers(passenger_id),
    FOREIGN KEY (booking_id)   REFERENCES bookings(booking_id)
);

CREATE TABLE extras (
    extra_id    INTEGER PRIMARY KEY,
    extra_name  TEXT NOT NULL UNIQUE,
    price       REAL NOT NULL CHECK (price > 0)                       -- ratio
);

-- Three-part compound key, with a compound foreign key pointing at the ticket it was bought for
CREATE TABLE ticket_extras (
    flight_id     INTEGER NOT NULL,
    passenger_id  INTEGER NOT NULL,
    extra_id      INTEGER NOT NULL,
    price_paid    REAL NOT NULL CHECK (price_paid > 0),               -- price at time of sale
    PRIMARY KEY (flight_id, passenger_id, extra_id),
    FOREIGN KEY (flight_id, passenger_id) REFERENCES tickets(flight_id, passenger_id),
    FOREIGN KEY (extra_id) REFERENCES extras(extra_id)
);

CREATE INDEX idx_aircraft_airline   ON aircraft(airline_id);
CREATE INDEX idx_flights_route_time ON flights(route_id, departure_datetime);
CREATE INDEX idx_flights_time       ON flights(departure_datetime);
CREATE INDEX idx_passengers_last    ON passengers(last_name);
CREATE INDEX idx_bookings_booker    ON bookings(booker_id);
CREATE INDEX idx_tickets_booking    ON tickets(booking_id);
CREATE INDEX idx_tickets_passenger  ON tickets(passenger_id);
CREATE INDEX idx_extras_extra       ON ticket_extras(extra_id);

-- Calculated values are views, not stored columns, so they cannot go out of sync.
CREATE VIEW flight_overview AS
SELECT f.flight_id, f.flight_number,
       o.iata_code AS origin, d.iata_code AS destination,
       f.departure_datetime,
       -- arrival in the destination's local time: duration + delay, shifted by the time zone difference
       datetime(f.departure_datetime,
                printf('%+d minutes', CAST(f.duration_minutes + COALESCE(f.delay_minutes, 0)
                                           + (d.utc_offset_hours - o.utc_offset_hours) * 60 AS INTEGER))) AS arrival_local,
       f.status, f.delay_minutes
FROM flights f
JOIN routes   r ON r.route_id   = f.route_id
JOIN airports o ON o.airport_id = r.origin_airport_id
JOIN airports d ON d.airport_id = r.destination_airport_id;

CREATE VIEW booking_totals AS
SELECT booking_id, tickets, fares, extras, ROUND(fares + extras, 2) AS total_paid
FROM (SELECT t.booking_id,
             COUNT(*) AS tickets,
             ROUND(SUM(t.fare_paid), 2) AS fares,
             ROUND(SUM(COALESCE((SELECT SUM(te.price_paid) FROM ticket_extras te
                                 WHERE te.flight_id = t.flight_id AND te.passenger_id = t.passenger_id), 0)), 2) AS extras
      FROM tickets 

INSERT INTO airlines (airline_name, iata_code, country, founded_year) VALUES
 ('SkyBridge Airways','SB','United Kingdom',1987),('Meridian Air','MR','United Arab Emirates',1998),
 ('Nimbus Airlines','NB','United States',1975),('Falcon Express','FE','Germany',2004),
 ('Aurora Airways','AU','Singapore',1992),('Pelican Air','PL','Ireland',2010);

INSERT INTO airports (iata_code, airport_name, city, country, airport_size, utc_offset_hours) VALUES
 ('LHR','London Heathrow','London','United Kingdom','Major Hub',0),
 ('JFK','John F. Kennedy International','New York','United States','Major Hub',-5),
 ('DXB','Dubai International','Dubai','United Arab Emirates','Major Hub',4),
 ('CDG','Paris Charles de Gaulle','Paris','France','Major Hub',1),
 ('FRA','Frankfurt Airport','Frankfurt','Germany','Major Hub',1),
 ('AMS','Amsterdam Schiphol','Amsterdam','Netherlands','Major Hub',1),
 ('MAD','Madrid Barajas','Madrid','Spain','International',1),
 ('FCO','Rome Fiumicino','Rome','Italy','International',1),
 ('IST','Istanbul Airport','Istanbul','Turkey','Major Hub',3),
 ('DEL','Indira Gandhi International','Delhi','India','Major Hub',5.5),
 ('ISB','Islamabad International','Islamabad','Pakistan','National',5),
 ('SIN','Singapore Changi','Singapore','Singapore','Major Hub',8),
 ('HKG','Hong Kong International','Hong Kong','Hong Kong','Major Hub',8),
 ('SYD','Sydney Kingsford Smith','Sydney','Australia','International',10),
 ('LAX','Los Angeles International','Los Angeles','United States','Major Hub',-8),
 ('YYZ','Toronto Pearson','Toronto','Canada','International',-5),
 ('MAN','Manchester Airport','Manchester','United Kingdom','International',0),
 ('DUB','Dublin Airport','Dublin','Ireland','International',0),
 ('JED','King Abdulaziz International','Jeddah','Saudi Arabia','International',3),
 ('LOS','Murtala Muhammed International','Lagos','Nigeria','National',1);

INSERT INTO extras (extra_name, price) VALUES
 ('Extra Baggage',40.00),('Priority Boarding',12.00),('Seat Selection',15.00),
 ('In-flight Meal',14.00),('Lounge Access',35.00),('Travel Insurance',28.00),
 ('Wi-Fi',9.00),('Fast Track Security',8.00);



CREATE TEMP TABLE route_pairs (pair_id INTEGER PRIMARY KEY, a TEXT, b TEXT, km INTEGER);
INSERT INTO route_pairs (a, b, km) VALUES
 ('LHR','JFK',5540),('LHR','DXB',5500),('LHR','CDG',344),('LHR','AMS',370),('LHR','DUB',450),
 ('MAN','DUB',220),('JFK','LAX',3980),('LHR','FRA',650),('DXB','DEL',2200),('LHR','MAD',1260),
 ('LHR','FCO',1430),('LHR','IST',2500),('CDG','JFK',5830),('DXB','ISB',1950),('LHR','ISB',5950),
 ('LHR','DEL',6700),('DXB','SIN',5840),('FRA','JFK',6200),('CDG','MAD',1050),('AMS','IST',2200),
 ('JFK','YYZ',590),('SIN','HKG',2590),('SIN','SYD',6300),('LHR','LAX',8760),('DXB','JED',1700),
 ('MAN','JFK',5330),('LHR','SIN',10850),('LHR','LOS',5000),('DXB','HKG',5950),('IST','ISB',3900);

CREATE TEMP TABLE aircraft_models (model_id INTEGER PRIMARY KEY, model TEXT, body_type TEXT, capacity INTEGER);
INSERT INTO aircraft_models (model, body_type, capacity) VALUES
 ('Airbus A320','Narrow-body',180),('Boeing 737-800','Narrow-body',189),('Airbus A321','Narrow-body',220),
 ('Boeing 787-9','Wide-body',290),('Airbus A350-900','Wide-body',325),('Boeing 777-300ER','Wide-body',370);

CREATE TEMP TABLE first_names (id INTEGER PRIMARY KEY, name TEXT, gender TEXT);
INSERT INTO first_names (name, gender) VALUES
 ('James','Male'),('Olivia','Female'),('Mohammed','Male'),('Amelia','Female'),('Oliver','Male'),
 ('Fatima','Female'),('Noah','Male'),('Priya','Female'),('Harry','Male'),('Sophia','Female'),
 ('Ali','Male'),('Emily','Female'),('George','Male'),('Aisha','Female'),('Jack','Male'),
 ('Chloe','Female'),('Daniel','Male'),('Zara','Female'),('Liam','Male'),('Hannah','Female'),
 ('Thomas','Male'),('Grace','Female'),('Arthur','Male'),('Ruby','Female'),('Samuel','Male'),
 ('Isla','Female'),('Hassan','Male'),('Maryam','Female'),('Ethan','Male'),('Lily','Female');

CREATE TEMP TABLE last_names (id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO last_names (name) VALUES
 ('Smith'),('Jones'),('Khan'),('Taylor'),('Brown'),('Patel'),('Wilson'),('Evans'),('Ahmed'),('Thomas'),
 ('Roberts'),('Walker'),('Wright'),('Hussain'),('Green'),('Hall'),('Clarke'),('Singh'),('Lewis'),('Murphy'),
 ('Davies'),('Johnson'),('Shah'),('Begum'),('Cooper'),('Morgan'),('Bell'),('Mahmood'),('Turner'),('Hughes');

-- cumulative weights out of 100
CREATE TEMP TABLE nationalities (nationality TEXT, cum_weight INTEGER);
INSERT INTO nationalities VALUES
 ('British',30),('American',42),('Indian',52),('German',60),('French',67),('Pakistani',73),
 ('Spanish',78),('Italian',83),('Irish',87),('Nigerian',91),('Chinese',96),('Turkish',100);

CREATE TEMP TABLE slots (slot INTEGER);
INSERT INTO slots VALUES (1),(2),(3),(4);



INSERT INTO routes (route_id, origin_airport_id, destination_airport_id, distance_km)
SELECT 2 * p.pair_id - 2 + d.dir,
       CASE d.dir WHEN 1 THEN ap.airport_id ELSE bp.airport_id END,
       CASE d.dir WHEN 1 THEN bp.airport_id ELSE ap.airport_id END,
       p.km
FROM route_pairs p
JOIN (SELECT 1 AS dir UNION ALL SELECT 2) d
JOIN airports ap ON ap.iata_code = p.a
JOIN airports bp ON bp.iata_code = p.b;


CREATE TEMP TABLE stg_aircraft AS
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 36)
SELECT n, abs(random() % 3) AS model_r, abs(random() % 20) AS year_r FROM seq;

INSERT INTO aircraft (aircraft_id, airline_id, registration, model, body_type, seat_capacity, manufacture_year)
SELECT s.n, (s.n - 1) / 6 + 1,
       a.iata_code || '-' || printf('%03d', s.n),
       m.model, m.body_type, m.capacity,
       2005 + s.year_r
FROM stg_aircraft s
JOIN airlines a ON a.airline_id = (s.n - 1) / 6 + 1
JOIN aircraft_models m ON m.model_id = CASE WHEN (s.n - 1) % 6 < 3 THEN 1 + s.model_r ELSE 4 + s.model_r END;


CREATE TEMP TABLE stg_flights AS
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 4000)
SELECT n,
       abs(random() % 1000000) / 1000000.0 AS pair_r,
       abs(random() % 2)   AS dir_r,
       abs(random() % 365) AS date_r,
       abs(random() % 18)  AS hour_r,
       abs(random() % 4)   AS min_r,
       abs(random() % 6)   AS airline_r,
       abs(random() % 3)   AS k_r,
       abs(random() % 100) AS wide_r,
       abs(random() % 21)  AS dur_r,
       abs(random() % 100) AS status_r,
       abs(random() % 100) AS delay_r,
       abs(random() % 150) AS dx_r
FROM seq;

WITH
f1 AS (
  SELECT s.*, 2 * (1 + CAST(((s.pair_r + s.pair_r * s.pair_r) / 2.0) * 30 AS INT)) - 1 + s.dir_r AS route_id
  FROM stg_flights s),
f2 AS (
  SELECT f1.*, r.distance_km, date('2026-01-01', '+' || f1.date_r || ' days') AS dep_date
  FROM f1 JOIN routes r ON r.route_id = f1.route_id),
f3 AS (
  SELECT f2.*,
         CASE WHEN distance_km > 4000 OR (distance_km > 1500 AND wide_r < 20) THEN 3 + k_r ELSE k_r END AS k,
         CASE WHEN dep_date > '2026-10-31'
              THEN CASE WHEN status_r < 2 THEN 'Cancelled' ELSE 'Scheduled' END
              ELSE CASE WHEN status_r < 3 THEN 'Cancelled' ELSE 'Arrived' END END AS flight_status
  FROM f2)
INSERT INTO flights (flight_number, route_id, aircraft_id, departure_datetime, duration_minutes, status, delay_minutes)
SELECT al.iata_code || printf('%03d', 100 + f3.route_id),
       f3.route_id,
       ac.aircraft_id,
       f3.dep_date || ' ' || printf('%02d:%02d', 5 + f3.hour_r, f3.min_r * 15),
       CAST(f3.distance_km / 820.0 * 60 + 30 + f3.dur_r - 10 AS INT),
       f3.flight_status,
       CASE WHEN f3.flight_status <> 'Arrived' THEN NULL
            WHEN f3.delay_r < 55 THEN 0
            WHEN f3.delay_r < 80 THEN 5 + f3.dx_r % 25
            WHEN f3.delay_r < 93 THEN 30 + f3.dx_r % 60
            ELSE 90 + f3.dx_r END
FROM f3
JOIN aircraft ac ON ac.aircraft_id = f3.airline_r * 6 + 1 + f3.k
JOIN airlines al ON al.airline_id  = ac.airline_id
ORDER BY 4;

-- Passengers (4000) ---
CREATE TEMP TABLE stg_passengers AS
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 4000)
SELECT n,
       abs(random() % 30) + 1 AS fn_id,
       abs(random() % 30) + 1 AS ln_id,
       abs(random() % 100)    AS gender_r,
       abs(random() % 100)    AS nat_r,
       abs(random() % 100)    AS grp_r,
       abs(random() % 20)     AS a1,     -- three draws added together give a bell-shaped adult age
       abs(random() % 20)     AS a2,
       abs(random() % 20)     AS a3,
       abs(random() % 14)     AS ch_r,
       abs(random() % 365)    AS days_r,
       abs(random() % 100)    AS tier_r
FROM seq;

WITH base AS (
  SELECT s.*, f.name AS fn, l.name AS ln, f.gender AS fg,
         CASE WHEN s.grp_r < 10 THEN 2 + s.ch_r ELSE 18 + s.a1 + s.a2 + s.a3 END AS age_years
  FROM stg_passengers s
  JOIN first_names f ON f.id = s.fn_id
  JOIN last_names  l ON l.id = s.ln_id)
INSERT INTO passengers (passenger_id, first_name, last_name, gender, date_of_birth, nationality, loyalty_tier, email)
SELECT n, fn, ln,
       CASE WHEN gender_r < 99 THEN fg ELSE 'Other' END,
       date('2026-10-31', '-' || (age_years * 365 + days_r) || ' days'),
       (SELECT nationality FROM nationalities WHERE cum_weight > nat_r ORDER BY cum_weight LIMIT 1),
       CASE WHEN age_years < 18 THEN 'Standard'
            WHEN tier_r < 60 THEN 'Standard' WHEN tier_r < 82 THEN 'Silver'
            WHEN tier_r < 94 THEN 'Gold' ELSE 'Platinum' END,
       lower(fn) || '.' || lower(ln) || n || '@example.com'
FROM base;



CREATE TEMP TABLE adult_pass (rn INTEGER PRIMARY KEY, passenger_id INTEGER);
INSERT INTO adult_pass
SELECT ROW_NUMBER() OVER (ORDER BY passenger_id), passenger_id
FROM passengers WHERE date_of_birth <= '2008-10-31';

CREATE TEMP TABLE bookable (rn INTEGER PRIMARY KEY, flight_id INTEGER);
INSERT INTO bookable
SELECT ROW_NUMBER() OVER (ORDER BY flight_id), flight_id
FROM flights WHERE status <> 'Cancelled';

CREATE TEMP TABLE stg_trips AS
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 3500)
SELECT n,
       abs(random() % 1000000) / 1000000.0 AS booker_r,
       abs(random() % 1000000) / 1000000.0 AS flight_r,
       abs(random() % 1000000) / 1000000.0 AS lead_r,
       abs(random() % 100) AS party_r,
       abs(random() % 100) AS trip_r,
       abs(random() % 13)  AS stay_r,
       abs(random() % 100) AS chan_r,
       abs(random() % 100) AS pay_r,
       abs(random() % 100) AS class_r,
       abs(random() % 100000) AS c2,
       abs(random() % 100000) AS c3,
       abs(random() % 100000) AS c4
FROM seq;

CREATE TEMP TABLE trips AS
WITH t1 AS (
  SELECT s.*, ap.passenger_id AS booker_id, f.flight_id AS out_flight_id,
         f.departure_datetime AS out_dt, f.route_id AS out_route,
         pax.last_name AS booker_last, pax.loyalty_tier AS tier
  FROM stg_trips s
  JOIN adult_pass ap ON ap.rn = 1 + CAST(((s.booker_r + s.booker_r * s.booker_r) / 2.0)
                                         * (SELECT COUNT(*) FROM adult_pass) AS INT)
  JOIN bookable   bf ON bf.rn = 1 + CAST(s.flight_r * (SELECT COUNT(*) FROM bookable) AS INT)
  JOIN flights     f ON f.flight_id = bf.flight_id
  JOIN passengers pax ON pax.passenger_id = ap.passenger_id)
SELECT t1.n AS trip_id, t1.booker_id, t1.out_flight_id, t1.booker_last,
       CASE WHEN t1.party_r < 55 THEN 1 WHEN t1.party_r < 83 THEN 2 WHEN t1.party_r < 92 THEN 3 ELSE 4 END AS party_size,
       CASE WHEN t1.trip_r < 60 THEN
            (SELECT f2.flight_id FROM flights f2
             WHERE f2.route_id = CASE WHEN t1.out_route % 2 = 1 THEN t1.out_route + 1 ELSE t1.out_route - 1 END
               AND f2.status <> 'Cancelled'
               AND f2.departure_datetime >= date(t1.out_dt, '+' || (2 + t1.stay_r) || ' days')
               AND f2.departure_datetime <  date(t1.out_dt, '+' || (2 + t1.stay_r + 31) || ' days')
             ORDER BY f2.departure_datetime LIMIT 1) END AS ret_flight_id,
       min(date(t1.out_dt, '-' || (1 + CAST(t1.lead_r * t1.lead_r * 200 AS INT)) || ' days'), '2026-10-31') AS booking_date,
       t1.chan_r, t1.pay_r,
       -- Gold and Platinum members fly in the higher classes more often
       CASE WHEN t1.tier IN ('Gold','Platinum')
            THEN CASE WHEN t1.class_r < 50 THEN 'Economy' WHEN t1.class_r < 70 THEN 'Premium Economy'
                      WHEN t1.class_r < 94 THEN 'Business' ELSE 'First' END
            ELSE CASE WHEN t1.class_r < 78 THEN 'Economy' WHEN t1.class_r < 90 THEN 'Premium Economy'
                      WHEN t1.class_r < 98 THEN 'Business' ELSE 'First' END END AS seat_class,
       t1.c2, t1.c3, t1.c4
FROM t1;


WITH r AS (SELECT trip_id, (trip_id * 48271) % 2147483647 AS sc FROM trips)
INSERT INTO bookings (booking_id, booking_reference, booker_id, booking_date, booking_channel, payment_method, trip_type)
SELECT t.trip_id,
       substr('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ', r.sc % 36 + 1, 1)
    || substr('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ', (r.sc / 36) % 36 + 1, 1)
    || substr('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ', (r.sc / 1296) % 36 + 1, 1)
    || substr('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ', (r.sc / 46656) % 36 + 1, 1)
    || substr('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ', (r.sc / 1679616) % 36 + 1, 1)
    || substr('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ', (r.sc / 60466176) % 36 + 1, 1),
       t.booker_id, t.booking_date,
       CASE WHEN t.chan_r < 45 THEN 'Website' WHEN t.chan_r < 80 THEN 'Mobile App'
            WHEN t.chan_r < 93 THEN 'Travel Agent' ELSE 'Call Centre' END,
       CASE WHEN t.pay_r < 40 THEN 'Credit Card' WHEN t.pay_r < 68 THEN 'Debit Card'
            WHEN t.pay_r < 86 THEN 'PayPal' WHEN t.pay_r < 96 THEN 'Digital Wallet' ELSE 'Bank Transfer' END,
       CASE WHEN t.ret_flight_id IS NULL THEN 'One-way' ELSE 'Round-trip' END
FROM trips t JOIN r ON r.trip_id = t.trip_id;


CREATE TEMP TABLE companion_candidates AS
SELECT t.trip_id, p2.passenger_id,
       ROW_NUMBER() OVER (
           PARTITION BY t.trip_id
           ORDER BY (p2.passenger_id * 7919 + t.c2) % 10007
       ) AS companion_no
FROM trips t
JOIN passengers p2
  ON p2.last_name = t.booker_last
 AND p2.passenger_id <> t.booker_id;

CREATE TEMP TABLE trip_pax AS
SELECT trip_id, 1 AS slot, booker_id AS passenger_id
FROM trips
UNION ALL
SELECT t.trip_id, sl.slot, cc.passenger_id
FROM trips t
JOIN slots sl ON sl.slot BETWEEN 2 AND t.party_size
JOIN companion_candidates cc
  ON cc.trip_id = t.trip_id
 AND cc.companion_no = sl.slot - 1;

CREATE TEMP TABLE legs AS
SELECT trip_id, out_flight_id AS flight_id FROM trips
UNION ALL
SELECT trip_id, ret_flight_id FROM trips WHERE ret_flight_id IS NOT NULL;

CREATE TEMP TABLE stg_tickets AS
SELECT tp.trip_id, tp.passenger_id, l.flight_id,
       abs(random() % 21)  AS fare_r,
       abs(random() % 100) AS bag_r,
       abs(random() % 100) AS meal_r
FROM trip_pax tp JOIN legs l ON l.trip_id = tp.trip_id;

WITH x AS (
  SELECT st.*, t.booking_date, t.seat_class, f.departure_datetime, r.distance_km, p.date_of_birth
  FROM stg_tickets st
  JOIN trips t ON t.trip_id = st.trip_id
  JOIN flights f ON f.flight_id = st.flight_id
  JOIN routes r ON r.route_id = f.route_id
  JOIN passengers p ON p.passenger_id = st.passenger_id)
INSERT OR IGNORE INTO tickets (flight_id, passenger_id, booking_id, seat_class, fare_paid, checked_bags, meal_preference)
SELECT flight_id, passenger_id, trip_id, seat_class,
       ROUND((35 + distance_km * 0.09)
             * CASE seat_class WHEN 'Economy' THEN 1.0 WHEN 'Premium Economy' THEN 1.6
                               WHEN 'Business' THEN 3.0 ELSE 5.0 END
             * CASE WHEN julianday(date(departure_datetime)) - julianday(booking_date) < 7 THEN 1.4
                    WHEN julianday(date(departure_datetime)) - julianday(booking_date) < 21 THEN 1.15
                    WHEN julianday(date(departure_datetime)) - julianday(booking_date) < 60 THEN 1.0
                    ELSE 0.85 END
             * CASE WHEN date_of_birth > '2010-10-31' THEN 0.75 ELSE 1.0 END
             * (0.9 + fare_r / 100.0), 2),
       CASE WHEN seat_class IN ('Business','First')
            THEN max(1, CASE WHEN bag_r < 30 THEN 0 WHEN bag_r < 75 THEN 1 WHEN bag_r < 95 THEN 2 ELSE 3 END)
            ELSE CASE WHEN bag_r < 30 THEN 0 WHEN bag_r < 75 THEN 1 WHEN bag_r < 95 THEN 2 ELSE 3 END END,
       CASE WHEN meal_r < 62 THEN 'Standard' WHEN meal_r < 76 THEN 'Vegetarian' WHEN meal_r < 81 THEN 'Vegan'
            WHEN meal_r < 91 THEN 'Halal' WHEN meal_r < 93 THEN 'Kosher' ELSE 'Gluten-free' END
FROM x;

DELETE FROM bookings WHERE booking_id NOT IN (SELECT booking_id FROM tickets);

CREATE TEMP TABLE stg_tsat AS
SELECT t.flight_id, t.passenger_id, t.seat_class, f.delay_minutes,
       abs(random() % 100) AS skip_r, abs(random() % 100) AS sat_r
FROM tickets t JOIN flights f ON f.flight_id = t.flight_id
WHERE f.status = 'Arrived';

CREATE TEMP TABLE stg_tsat2 AS
SELECT flight_id, passenger_id, skip_r,
       sat_r - (CASE WHEN delay_minutes > 120 THEN 30 WHEN delay_minutes > 45 THEN 15
                     WHEN delay_minutes > 0 THEN 5 ELSE 0 END)
             + (CASE WHEN seat_class IN ('Business','First') THEN 10 ELSE 0 END) AS adj
FROM stg_tsat;

UPDATE tickets
SET satisfaction_score = (
    SELECT CASE WHEN s.skip_r < 40 THEN NULL
                WHEN s.adj < 8  THEN 1
                WHEN s.adj < 20 THEN 2
                WHEN s.adj < 40 THEN 3
                WHEN s.adj < 68 THEN 4
                ELSE 5 END
    FROM stg_tsat2 s
    WHERE s.flight_id = tickets.flight_id AND s.passenger_id = tickets.passenger_id);


CREATE TEMP TABLE stg_xt AS
SELECT t.flight_id, t.passenger_id, e.extra_id, t.seat_class, t.checked_bags, r.distance_km,
       abs(random() % 100) AS x_r
FROM tickets t
JOIN flights f ON f.flight_id = t.flight_id
JOIN routes  r ON r.route_id  = f.route_id
CROSS JOIN extras e
WHERE e.extra_id IN (1, 2, 3, 4, 5, 7);

INSERT INTO ticket_extras (flight_id, passenger_id, extra_id, price_paid)
SELECT x.flight_id, x.passenger_id, x.extra_id, e.price
FROM stg_xt x
JOIN extras e ON e.extra_id = x.extra_id
WHERE x.x_r < CASE x.extra_id
        WHEN 1 THEN CASE WHEN x.checked_bags >= 2 THEN 45 ELSE 12 END
        WHEN 2 THEN CASE WHEN x.seat_class IN ('Business','First') THEN 3 ELSE 18 END
        WHEN 3 THEN CASE WHEN x.seat_class = 'Economy' THEN 35 ELSE 10 END
        WHEN 4 THEN CASE WHEN x.distance_km > 2500 THEN 40 ELSE 15 END
        WHEN 5 THEN CASE WHEN x.seat_class IN ('Business','First') THEN 45 ELSE 5 END
        WHEN 7 THEN CASE WHEN x.distance_km > 4000 THEN 25 ELSE 8 END
      END;


CREATE TEMP TABLE stg_x2 AS
SELECT flight_id, passenger_id, abs(random() % 100) AS ins_r, abs(random() % 100) AS fast_r
FROM tickets;

INSERT OR IGNORE INTO ticket_extras (flight_id, passenger_id, extra_id, price_paid)
SELECT x.flight_id, x.passenger_id, 6, (SELECT price FROM extras WHERE extra_id = 6)
FROM stg_x2 x
WHERE x.ins_r < CASE WHEN EXISTS (SELECT 1 FROM ticket_extras te
                                  WHERE te.flight_id = x.flight_id AND te.passenger_id = x.passenger_id
                                    AND te.extra_id = 1) THEN 45 ELSE 10 END;

INSERT OR IGNORE INTO ticket_extras (flight_id, passenger_id, extra_id, price_paid)
SELECT x.flight_id, x.passenger_id, 8, (SELECT price FROM extras WHERE extra_id = 8)
FROM stg_x2 x
WHERE x.fast_r < CASE WHEN EXISTS (SELECT 1 FROM ticket_extras te
                                   WHERE te.flight_id = x.flight_id AND te.passenger_id = x.passenger_id
                                     AND te.extra_id IN (2, 5)) THEN 60 ELSE 4 END;

DROP TABLE stg_aircraft;   DROP TABLE stg_flights;  DROP TABLE stg_passengers; DROP TABLE stg_trips;
DROP TABLE stg_tickets;    DROP TABLE stg_tsat;     DROP TABLE stg_tsat2;      DROP TABLE stg_xt;
DROP TABLE stg_x2;         DROP TABLE trips;        DROP TABLE trip_pax;       DROP TABLE legs;
DROP TABLE companion_candidates;
DROP TABLE adult_pass;     DROP TABLE bookable;     DROP TABLE route_pairs;    DROP TABLE aircraft_models;
DROP TABLE first_names;    DROP TABLE last_names;   DROP TABLE nationalities;  DROP TABLE slots;

-- Checks (uncomment one at a time) ---------------------------------------
-- SELECT 'flights', COUNT(*) FROM flights UNION ALL SELECT 'passengers', COUNT(*) FROM passengers
--   UNION ALL SELECT 'bookings', COUNT(*) FROM bookings UNION ALL SELECT 'tickets', COUNT(*) FROM tickets
--   UNION ALL SELECT 'ticket_extras', COUNT(*) FROM ticket_extras;
-- PRAGMA foreign_key_check;
-- SELECT o.iata_code || '-' || d.iata_code AS route, COUNT(*) AS flights FROM flights f
--   JOIN routes r USING (route_id) JOIN airports o ON o.airport_id = r.origin_airport_id
--   JOIN airports d ON d.airport_id = r.destination_airport_id GROUP BY 1 ORDER BY flights DESC LIMIT 10;
-- SELECT a.extra_id, b.extra_id, COUNT(*) AS together FROM ticket_extras a
--   JOIN ticket_extras b ON a.flight_id = b.flight_id AND a.passenger_id = b.passenger_id AND a.extra_id < b.extra_id
--   GROUP BY 1, 2 ORDER BY together DESC LIMIT 10;

-- Final verification: row counts for the main generated tables
SELECT 'flights' AS table_name, COUNT(*) AS row_count FROM flights
UNION ALL SELECT 'passengers', COUNT(*) FROM passengers
UNION ALL SELECT 'bookings', COUNT(*) FROM bookings
UNION ALL SELECT 'tickets', COUNT(*) FROM tickets
UNION ALL SELECT 'ticket_extras', COUNT(*) FROM ticket_extras;

-- Association-rule starting point: extras frequently purchased together
-- Support is the percentage of tickets containing both extras.
WITH ticket_count AS (
    SELECT COUNT(*) AS n FROM tickets
), pair_counts AS (
    SELECT a.extra_id AS extra_a, b.extra_id AS extra_b, COUNT(*) AS pair_frequency
    FROM ticket_extras a
    JOIN ticket_extras b
      ON a.flight_id = b.flight_id
     AND a.passenger_id = b.passenger_id
     AND a.extra_id < b.extra_id
    GROUP BY a.extra_id, b.extra_id
)
SELECT ea.extra_name AS extra_a, eb.extra_name AS extra_b,
       pc.pair_frequency,
       ROUND(100.0 * pc.pair_frequency / tc.n, 2) AS support_percent
FROM pair_counts pc
JOIN extras ea ON ea.extra_id = pc.extra_a
JOIN extras eb ON eb.extra_id = pc.extra_b
CROSS JOIN ticket_count tc
ORDER BY pc.pair_frequency DESC
LIMIT 20;

-- Run this separately if you want to confirm there are no broken foreign keys:
-- PRAGMA foreign_key_check;
