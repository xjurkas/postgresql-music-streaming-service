#!/usr/bin/env python3

# generate_seed.py
# Vygeneruje seed.sql s INSERT prikazmi pre databazu hudobnej streamovacej sluzby.
#
# Pouzitie:
#   pip install Faker
#   python3 generate_seed.py
#
# Vystup:  seed.sql  (spustitelny cez:  psql -d <dbname> -f seed.sql)


import random
from datetime import datetime, timedelta

try:
    from faker import Faker
    fake = Faker()
    HAS_FAKER = True
except ImportError:
    HAS_FAKER = False
    print("WARN: Faker nie je nainstalovany, pouzivam fallback generator.")
    print("      Pre lepsie data spusti: pip install Faker")

# Fixny seed kvoli reprodukovatelnosti
random.seed(42)
if HAS_FAKER:
    Faker.seed(42)

# KONFIGURACIA POCTOV (uprav podla potreby)
N_USERS         = 2000
N_DEVICES       = 3500   # priemer
N_ADS           = 50
N_IMPRESSIONS   = 8000
N_SONGS         = 3000
N_PLAYLISTS_AVG = 1800   # priemer
# Queue_Song a Playlist_Song sa pocitaju automaticky podla distribucie

# Distribucia roli (USER, PREMIUM_USER, ARTIST, ADMIN)
ROLE_WEIGHTS = {
    1: 1595,  # USER
    2: 250,   # PREMIUM_USER
    3: 150,   # ARTIST
    4: 5,     # ADMIN
}


def sql_str(s):
    """Escapne string pre SQL (zdvoji apostrofy)."""
    if s is None:
        return 'NULL'
    return "'" + str(s).replace("'", "''") + "'"


def sql_bool(b):
    return 'TRUE' if b else 'FALSE'


def sql_ts(dt):
    return "'" + dt.strftime('%Y-%m-%d %H:%M:%S') + "'"


# Fallback generatory ak nie je Faker
FIRST_NAMES = ['Adam', 'Eva', 'Peter', 'Lucia', 'Martin', 'Jana', 'Tomas', 'Anna',
               'Jakub', 'Maria', 'Filip', 'Zuzana', 'Michal', 'Petra', 'Dominik',
               'Katarina', 'Pavol', 'Veronika', 'Andrej', 'Simona', 'Lukas', 'Nina']
LAST_NAMES  = ['Novak', 'Horvath', 'Kovac', 'Varga', 'Toth', 'Nagy', 'Balog',
               'Sabo', 'Molnar', 'Lukac', 'Hudak', 'Marek', 'Polak', 'Urban',
               'Vlcek', 'Krajci', 'Holub', 'Sedlak', 'Bartos', 'Kucera']

def gen_name():
    if HAS_FAKER:
        return fake.name()
    return random.choice(FIRST_NAMES) + ' ' + random.choice(LAST_NAMES)


def gen_password_hash():
    """Fake bcrypt-style hash (60 znakov)."""
    chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./'
    return '$2b$12$' + ''.join(random.choice(chars) for _ in range(53))


SONG_WORDS = ['Sunset', 'Dream', 'Heart', 'Fire', 'Rain', 'Sky', 'Ocean', 'Light',
              'Dark', 'Soul', 'Star', 'Moon', 'Wind', 'Storm', 'Echo', 'Silent',
              'Wild', 'Lost', 'Free', 'Broken', 'Golden', 'Midnight', 'Endless',
              'Forever', 'Crystal', 'Shadow', 'Flame', 'River', 'Mountain', 'Road']

def gen_song_name():
    n = random.randint(1, 3)
    return ' '.join(random.choice(SONG_WORDS) for _ in range(n))


PLAYLIST_THEMES = ['Chill Vibes', 'Workout 2026', 'Road Trip', 'Sad Songs',
                   'Party Mix', 'Morning Coffee', 'Late Night', 'Focus',
                   'Throwback', 'Indie Discoveries', 'Rock Classics', 'Jazz Cafe',
                   'Summer 2026', 'Winter Mood', 'Study Session', 'Gym Pump',
                   'Sunday Morning', 'Friday Night', 'Lo-Fi Beats', 'Acoustic',
                   'Top Hits', 'Hidden Gems', 'Karaoke', 'Sleep', 'Meditation',
                   'Driving', 'Cooking', 'Cleaning', 'Running', 'Yoga']

DEVICE_NAMES = ['iPhone 14', 'iPhone 15', 'Samsung Galaxy S23', 'Samsung Galaxy S24',
                'Pixel 8', 'iPad Pro', 'iPad Air', 'MacBook Pro', 'MacBook Air',
                'Dell XPS 15', 'Lenovo ThinkPad', 'HP Spectre', 'Chrome on Windows',
                'Firefox on Linux', 'Safari on Mac', 'Edge on Windows', 'Android Tablet']

AD_BRANDS = ['Coca-Cola', 'Nike', 'Adidas', 'McDonalds', 'KFC', 'Apple', 'Samsung',
             'Netflix', 'Amazon', 'Toyota', 'BMW', 'Volkswagen', 'IKEA', 'Zara',
             'H&M', 'Spotify Premium', 'Audible', 'Booking.com', 'Airbnb', 'Uber']

QUEUE_NAMES = ['Up Next', 'My Queue', 'Now Playing']


def weighted_user_segment(segments):
    """segments: list of (count_users, weight) - vrati index segmentu."""
    weights = [s[0] for s in segments]
    return random.choices(range(len(segments)), weights=weights, k=1)[0]



# 1. ROLE
roles_sql = """
-- =============================================================================
-- SEED DATA pre Hudobnu streamovaciu sluzbu
-- Generovane skriptom generate_seed.py
-- =============================================================================

-- Vycistenie tabuliek (idempotentnost)
TRUNCATE TABLE Playlist_Song, Queue_Song, Playlist, Queue,
               Advertisment_Impression, Advertisment, Device, Song, "User", Role
RESTART IDENTITY CASCADE;

-- =============================================================================
-- 1. ROLE
-- =============================================================================
INSERT INTO Role (id, name, has_ads, can_upload) VALUES
    (1, 'USER',         TRUE,  FALSE),
    (2, 'PREMIUM_USER', FALSE, FALSE),
    (3, 'ARTIST',       TRUE,  TRUE),
    (4, 'ADMIN',        FALSE, TRUE);
SELECT setval('role_id_seq', 4);
"""


# 2. USER

print(f"Generujem {N_USERS} pouzivatelov...")

users = []  # list of (id, role_id, name, email, password)
role_pool = []
for role_id, count in ROLE_WEIGHTS.items():
    role_pool.extend([role_id] * count)
random.shuffle(role_pool)
role_pool = role_pool[:N_USERS]  # presne N_USERS

# Roztriedime userov podla rol
artist_ids = []
premium_ids = []
free_user_ids = []
admin_ids = []
ads_eligible_ids = []  # USER + ARTIST (has_ads = TRUE)

for i in range(1, N_USERS + 1):
    role_id = role_pool[i - 1]
    name = gen_name()
    # Garantovane unikatny email
    email = f"user{i}@example.com"
    password = gen_password_hash()
    users.append((i, role_id, name, email, password))

    if role_id == 1:
        free_user_ids.append(i)
        ads_eligible_ids.append(i)
    elif role_id == 2:
        premium_ids.append(i)
    elif role_id == 3:
        artist_ids.append(i)
        ads_eligible_ids.append(i)
    elif role_id == 4:
        admin_ids.append(i)

print(f"  USER: {len(free_user_ids)}, PREMIUM: {len(premium_ids)}, "
      f"ARTIST: {len(artist_ids)}, ADMIN: {len(admin_ids)}")

users_sql = '\n-- =============================================================================\n'
users_sql += '-- 2. USER\n'
users_sql += '-- =============================================================================\n'
users_sql += 'INSERT INTO "User" (id, role_id, name, email, password) VALUES\n'
rows = [f"    ({u[0]}, {u[1]}, {sql_str(u[2])}, {sql_str(u[3])}, {sql_str(u[4])})"
        for u in users]
users_sql += ',\n'.join(rows) + ';\n'
users_sql += f"SELECT setval('\"User_id_seq\"', {N_USERS});\n"



# 3. DEVICE

print(f"Generujem zariadenia...")

# Distribucia: 10% bez zariadenia, 40% s 1, 30% s 2, 15% s 3, 5% so 4-5
device_dist = [0, 1, 1, 1, 1, 2, 2, 2, 3, 4]  # weighted pool
devices = []
device_id = 1
for u in users:
    n = random.choices([0, 1, 2, 3, 4, 5],
                       weights=[10, 40, 30, 15, 4, 1], k=1)[0]
    for _ in range(n):
        name = random.choice(DEVICE_NAMES)
        is_active = random.random() < 0.80
        devices.append((device_id, u[0], name, is_active))
        device_id += 1

print(f"  Vygenerovanych zariadeni: {len(devices)}")

devices_sql = '\n-- =============================================================================\n'
devices_sql += '-- 3. DEVICE\n'
devices_sql += '-- =============================================================================\n'
if devices:
    devices_sql += 'INSERT INTO Device (id, user_id, name, is_active) VALUES\n'
    rows = [f"    ({d[0]}, {d[1]}, {sql_str(d[2])}, {sql_bool(d[3])})"
            for d in devices]
    devices_sql += ',\n'.join(rows) + ';\n'
    devices_sql += f"SELECT setval('device_id_seq', {len(devices)});\n"



# 4. ADVERTISMENT

print(f"Generujem {N_ADS} reklam...")

ads = []
for i in range(1, N_ADS + 1):
    name = f"{random.choice(AD_BRANDS)} Campaign {i}"
    is_active = random.random() < 0.70
    if HAS_FAKER:
        content = fake.text(max_nb_chars=200).replace('\n', ' ')
    else:
        content = f"Reklamny obsah pre kampan {i}. Specialna ponuka len pre vas!"
    ads.append((i, name, is_active, content))

ads_sql = '\n-- =============================================================================\n'
ads_sql += '-- 4. ADVERTISMENT\n'
ads_sql += '-- =============================================================================\n'
ads_sql += 'INSERT INTO Advertisment (id, name, is_active, content) VALUES\n'
rows = [f"    ({a[0]}, {sql_str(a[1])}, {sql_bool(a[2])}, {sql_str(a[3])})"
        for a in ads]
ads_sql += ',\n'.join(rows) + ';\n'
ads_sql += f"SELECT setval('advertisment_id_seq', {N_ADS});\n"

active_ad_ids = [a[0] for a in ads if a[2]]



# 5. ADVERTISMENT_IMPRESSION

print(f"Generujem {N_IMPRESSIONS} zobrazeni reklam...")

impressions = []
imp_id = 1

# Heavy users (top 10%) maju priem. 25 impressions, atd.
n_eligible = len(ads_eligible_ids)
random.shuffle(ads_eligible_ids)
heavy = ads_eligible_ids[:int(n_eligible * 0.10)]
medium = ads_eligible_ids[int(n_eligible * 0.10):int(n_eligible * 0.50)]
light = ads_eligible_ids[int(n_eligible * 0.50):int(n_eligible * 0.90)]
inactive = ads_eligible_ids[int(n_eligible * 0.90):]

# Vytvorime weighted pool userov pre impressions
imp_user_pool = []
imp_user_pool.extend(heavy * 25)     # heavy: 25x kazdy
imp_user_pool.extend(medium * 4)     # medium: 4x kazdy
imp_user_pool.extend(light * 1)      # light: 1x kazdy
# inactive maju ~0.5x v priemere
imp_user_pool.extend(random.sample(inactive, min(len(inactive)//2, len(inactive))))

random.shuffle(imp_user_pool)

now = datetime.now()
six_months_ago = now - timedelta(days=180)

for _ in range(N_IMPRESSIONS):
    if not imp_user_pool:
        # Fallback ak doslo
        user_id = random.choice(ads_eligible_ids)
    else:
        user_id = imp_user_pool.pop()

    ad_id = random.choice(active_ad_ids)
    # Random timestamp v poslednych 6 mesiacoch
    delta_seconds = random.randint(0, int((now - six_months_ago).total_seconds()))
    shown_at = six_months_ago + timedelta(seconds=delta_seconds)
    impressions.append((imp_id, user_id, ad_id, shown_at))
    imp_id += 1

# Pre velky pocet INSERTov rozdelime na batche po 1000
def chunked_insert(table, columns, rows, formatter, batch_size=1000):
    """Generuje SQL s viacerymi INSERT statementmi po batchoch."""
    out = []
    cols_str = ', '.join(columns)
    for i in range(0, len(rows), batch_size):
        batch = rows[i:i + batch_size]
        out.append(f'INSERT INTO {table} ({cols_str}) VALUES')
        out.append(',\n'.join(f"    {formatter(r)}" for r in batch) + ';')
    return '\n'.join(out)

impressions_sql = '\n-- =============================================================================\n'
impressions_sql += '-- 5. ADVERTISMENT_IMPRESSION\n'
impressions_sql += '-- =============================================================================\n'
impressions_sql += chunked_insert(
    'Advertisment_Impression',
    ['id', 'user_id', 'advertisment_id', 'shown_at'],
    impressions,
    lambda r: f"({r[0]}, {r[1]}, {r[2]}, {sql_ts(r[3])})"
)
impressions_sql += f"\nSELECT setval('advertisment_impression_id_seq', {len(impressions)});\n"



# 6. SONG

print(f"Generujem {N_SONGS} skladieb...")

# Distribucia skladieb na artistu (power-law)
n_artists = len(artist_ids)
random.shuffle(artist_ids)
top_artists = artist_ids[:max(1, int(n_artists * 0.07))]      # ~7%
active_artists = artist_ids[int(n_artists * 0.07):int(n_artists * 0.27)]   # ~20%
medium_artists = artist_ids[int(n_artists * 0.27):int(n_artists * 0.67)]   # ~40%
new_artists = artist_ids[int(n_artists * 0.67):]              # ~33%

# Vytvorime weighted pool
artist_pool = []
for a in top_artists:
    artist_pool.extend([a] * 60)    # ~60 skladieb
for a in active_artists:
    artist_pool.extend([a] * 25)
for a in medium_artists:
    artist_pool.extend([a] * 10)
for a in new_artists:
    artist_pool.extend([a] * 4)

random.shuffle(artist_pool)

songs = []
for i in range(1, N_SONGS + 1):
    name = gen_song_name()
    # Z weighted poolu
    if artist_pool:
        author_id = artist_pool.pop()
    else:
        author_id = random.choice(artist_ids)

    # Trvanie: normalne rozdelenie okolo 210s, clamp na [30, 600]
    duration = int(random.gauss(210, 60))
    duration = max(30, min(600, duration))

    is_approved = random.random() < 0.85  # 85% schvalenych
    songs.append((i, name, author_id, duration, is_approved))

approved_song_ids = [s[0] for s in songs if s[4]]
print(f"  Skladieb spolu: {len(songs)}, schvalenych: {len(approved_song_ids)}")

songs_sql = '\n-- =============================================================================\n'
songs_sql += '-- 6. SONG\n'
songs_sql += '-- =============================================================================\n'
songs_sql += chunked_insert(
    'Song',
    ['id', 'name', 'author_id', 'duration', 'is_approved'],
    songs,
    lambda r: f"({r[0]}, {sql_str(r[1])}, {r[2]}, {r[3]}, {sql_bool(r[4])})"
)
songs_sql += f"\nSELECT setval('song_id_seq', {len(songs)});\n"



# 7. QUEUE

print(f"Generujem queues...")

queues = []
for i, u in enumerate(users, start=1):
    name = random.choice(QUEUE_NAMES)
    queues.append((i, u[0], name))

queues_sql = '\n-- =============================================================================\n'
queues_sql += '-- 7. QUEUE\n'
queues_sql += '-- =============================================================================\n'
queues_sql += chunked_insert(
    'Queue',
    ['id', 'user_id', 'name'],
    queues,
    lambda r: f"({r[0]}, {r[1]}, {sql_str(r[2])})"
)
queues_sql += f"\nSELECT setval('queue_id_seq', {len(queues)});\n"



# 8. QUEUE_SONG

print(f"Generujem queue_song zaznamy...")

queue_songs = []
qs_id = 1

for q in queues:
    queue_id = q[0]
    # Distribucia: 30% prazdnych, 40% 1-3, 20% 4-10, 8% 11-30, 2% 31-50
    rnd = random.random()
    if rnd < 0.30:
        n = 0
    elif rnd < 0.70:
        n = random.randint(1, 3)
    elif rnd < 0.90:
        n = random.randint(4, 10)
    elif rnd < 0.98:
        n = random.randint(11, 30)
    else:
        n = random.randint(31, 50)

    if n == 0:
        continue

    # Vyber n unikatnych schvalenych skladieb
    n = min(n, len(approved_song_ids))
    chosen_songs = random.sample(approved_song_ids, n)
    for pos, song_id in enumerate(chosen_songs, start=1):
        queue_songs.append((qs_id, queue_id, song_id, pos))
        qs_id += 1

print(f"  Queue_Song zaznamov: {len(queue_songs)}")

qs_sql = '\n-- =============================================================================\n'
qs_sql += '-- 8. QUEUE_SONG\n'
qs_sql += '-- =============================================================================\n'
if queue_songs:
    qs_sql += chunked_insert(
        'Queue_Song',
        ['id', 'queue_id', 'song_id', 'queue_position'],
        queue_songs,
        lambda r: f"({r[0]}, {r[1]}, {r[2]}, {r[3]})"
    )
    qs_sql += f"\nSELECT setval('queue_song_id_seq', {len(queue_songs)});\n"



# 9. PLAYLIST

print(f"Generujem playlisty...")

playlists = []
pl_id = 1

# Distribucia: 40% bez playlistu, 35% 1-2, 20% 3-10, 5% 10+
all_user_ids = [u[0] for u in users]

for u_id in all_user_ids:
    rnd = random.random()
    if rnd < 0.60:        # 60% bez playlistu
        n = 0
    elif rnd < 0.85:      # 25% ma 1-2
        n = random.randint(1, 2)
    elif rnd < 0.97:      # 12% ma 3-7
        n = random.randint(3, 7)
    else:                 # 3% "curator" 8-15
        n = random.randint(8, 15)

    if n == 0:
        continue

    # Unikatne nazvy playlistov per user
    n = min(n, len(PLAYLIST_THEMES))
    chosen_names = random.sample(PLAYLIST_THEMES, n)
    for name in chosen_names:
        playlists.append((pl_id, u_id, name))
        pl_id += 1

print(f"  Playlistov: {len(playlists)}")

playlists_sql = '\n-- =============================================================================\n'
playlists_sql += '-- 9. PLAYLIST\n'
playlists_sql += '-- =============================================================================\n'
if playlists:
    playlists_sql += chunked_insert(
        'Playlist',
        ['id', 'user_id', 'name'],
        playlists,
        lambda r: f"({r[0]}, {r[1]}, {sql_str(r[2])})"
    )
    playlists_sql += f"\nSELECT setval('playlist_id_seq', {len(playlists)});\n"



# 10. PLAYLIST_SONG

print(f"Generujem playlist_song zaznamy...")

playlist_songs = []
ps_id = 1

for p in playlists:
    playlist_id = p[0]
    # Distribucia: 10% prazdnych, 40% 1-10, 35% 11-20, 12% 21-40, 3% 41-80
    rnd = random.random()
    if rnd < 0.10:               # 10% prazdnych
        n = 0
    elif rnd < 0.55:             # 45% ma 1-7
        n = random.randint(1, 7)
    elif rnd < 0.88:             # 33% ma 8-15
        n = random.randint(8, 15)
    elif rnd < 0.98:             # 10% ma 16-30
        n = random.randint(16, 30)
    else:                        # 2% mega 31-60
        n = random.randint(31, 60)

    if n == 0:
        continue

    n = min(n, len(approved_song_ids))
    chosen_songs = random.sample(approved_song_ids, n)
    for pos, song_id in enumerate(chosen_songs, start=1):
        playlist_songs.append((ps_id, playlist_id, song_id, pos))
        ps_id += 1

print(f"  Playlist_Song zaznamov: {len(playlist_songs)}")

ps_sql = '\n-- =============================================================================\n'
ps_sql += '-- 10. PLAYLIST_SONG\n'
ps_sql += '-- =============================================================================\n'
if playlist_songs:
    ps_sql += chunked_insert(
        'Playlist_Song',
        ['id', 'playlist_id', 'song_id', 'position'],
        playlist_songs,
        lambda r: f"({r[0]}, {r[1]}, {r[2]}, {r[3]})"
    )
    ps_sql += f"\nSELECT setval('playlist_song_id_seq', {len(playlist_songs)});\n"



# ZAPIS DO SUBORU

output = (roles_sql + users_sql + devices_sql + ads_sql + impressions_sql +
          songs_sql + queues_sql + qs_sql + playlists_sql + ps_sql)

# Sumar na konci
total = (4 + len(users) + len(devices) + len(ads) + len(impressions) +
         len(songs) + len(queues) + len(queue_songs) + len(playlists) +
         len(playlist_songs))

summary = f"""
-- =============================================================================
-- SUMAR VYGENEROVANYCH ZAZNAMOV
-- =============================================================================
-- Role:                       4
-- User:                       {len(users)}
-- Device:                     {len(devices)}
-- Advertisment:               {len(ads)}
-- Advertisment_Impression:    {len(impressions)}
-- Song:                       {len(songs)}
-- Queue:                      {len(queues)}
-- Queue_Song:                 {len(queue_songs)}
-- Playlist:                   {len(playlists)}
-- Playlist_Song:              {len(playlist_songs)}
-- -----------------------------------------------------------------
-- SPOLU:                      {total}
-- =============================================================================
"""

with open('seed.sql', 'w', encoding='utf-8') as f:
    f.write(output)
    f.write(summary)

print()
print("=" * 65)
print(f"Hotovo! Vygenerovanych celkom {total} zaznamov.")
print(f"Vystup: seed.sql")
print(f"Spustenie:  psql -d <dbname> -f seed.sql")
print("=" * 65)
