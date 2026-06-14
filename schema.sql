-- Zadanie 3
-- Tema: Hudobna streamovacia sluzba
-- Autori: Dominik Jurkas, Filip Hromada

-- TABULKA: Role
-- Reprezentuje typ pouzivatela (USER, PREMIUM_USER, ARTIST, ADMIN).
-- Atributy has_ads / can_upload riadia biznis pravidla systemu.
CREATE TABLE Role (
id SERIAL PRIMARY KEY,
name VARCHAR(100) NOT NULL UNIQUE,
has_ads BOOLEAN NOT NULL,
can_upload  BOOLEAN NOT NULL,
-- Nazov roly nesmie byt prazdny retazec
CONSTRAINT chk_role_name_not_empty CHECK (LENGTH(TRIM(name)) > 0)
);

-- TABULKA: User
-- Reprezentuje vsetkych pouzivatelov systemu (bezni, premium, artisti, admini).
-- Email musi byt unikatny, kazdy pouzivatel ma prave jednu rolu.
CREATE TABLE "User" (
id SERIAL PRIMARY KEY,
role_id INT NOT NULL,
name VARCHAR(100) NOT NULL,
email VARCHAR(100) NOT NULL UNIQUE,
password VARCHAR(255) NOT NULL,
CONSTRAINT fk_user_role
FOREIGN KEY (role_id) REFERENCES Role(id)
ON DELETE RESTRICT ON UPDATE CASCADE,
-- Email musi obsahovat aspon znak '@' a bodku za nim
CONSTRAINT chk_user_email_format CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
CONSTRAINT chk_user_name_not_empty CHECK (LENGTH(TRIM(name)) > 0),
-- Heslo je ulozene ako hash, takze ma rozumnu minimalnu dlzku
CONSTRAINT chk_user_password_min_length CHECK (LENGTH(password) >= 8)
);

-- TABULKA: Device
-- Zariadenia pouzivatela (mobil, tablet, PC). Pouzivatel moze mat viac zariadeni.
CREATE TABLE Device (
id SERIAL PRIMARY KEY,
user_id INT NOT NULL,
name VARCHAR(100) NOT NULL,
is_active BOOLEAN NOT NULL DEFAULT TRUE,
CONSTRAINT fk_device_user FOREIGN KEY (user_id) REFERENCES "User"(id)
ON DELETE CASCADE ON UPDATE CASCADE,
CONSTRAINT chk_device_name_not_empty
CHECK (LENGTH(TRIM(name)) > 0)
);

-- TABULKA: Advertisment
-- Globalne reklamy v systeme. Zobrazuju sa iba pouzivatelom, ktorych rola
-- ma has_ads = true.
CREATE TABLE Advertisment (
id SERIAL PRIMARY KEY,
name VARCHAR(100) NOT NULL,
is_active BOOLEAN NOT NULL DEFAULT TRUE,
content TEXT NOT NULL,
CONSTRAINT chk_ad_name_not_empty CHECK (LENGTH(TRIM(name)) > 0),
CONSTRAINT chk_ad_content_not_empty CHECK (LENGTH(TRIM(content)) > 0)
);

-- TABULKA: Advertisment_Impression
-- Zaznam o kazdom zobrazeni reklamy konkretnemu pouzivatelovi.
CREATE TABLE Advertisment_Impression (
id SERIAL PRIMARY KEY,
user_id INT NOT NULL,
advertisment_id INT NOT NULL,
shown_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
CONSTRAINT fk_impression_user FOREIGN KEY (user_id) REFERENCES "User"(id)
ON DELETE CASCADE ON UPDATE CASCADE,
CONSTRAINT fk_impression_ad
FOREIGN KEY (advertisment_id) REFERENCES Advertisment(id)
ON DELETE CASCADE ON UPDATE CASCADE,
-- Zobrazenie reklamy nemoze byt v buducnosti
CONSTRAINT chk_impression_shown_at_not_future CHECK (shown_at <= CURRENT_TIMESTAMP + INTERVAL '1 minute')
);

-- TABULKA: Song
-- Skladby nahrane pouzivatelmi s rolou ARTIST. Pred sprivstupnenim musi byt
-- skladba schvalena administratorom (is_approved = true).
CREATE TABLE Song (
id SERIAL PRIMARY KEY,
name VARCHAR(100) NOT NULL,
author_id INT NOT NULL,
duration INT NOT NULL,
is_approved BOOLEAN NOT NULL DEFAULT FALSE,
CONSTRAINT fk_song_author FOREIGN KEY (author_id) REFERENCES "User"(id)
ON DELETE RESTRICT ON UPDATE CASCADE,
CONSTRAINT chk_song_name_not_empty CHECK (LENGTH(TRIM(name)) > 0),
-- Trvanie skladby v sekundach musi byt kladne, max 2 hodiny
CONSTRAINT chk_song_duration_positive CHECK (duration > 0 AND duration <= 7200)
);

-- TABULKA: Queue
-- Kazdy pouzivatel ma prave jednu frontu prehravania (UNIQUE user_id => 1:1).
CREATE TABLE Queue (
id SERIAL PRIMARY KEY,
user_id INT NOT NULL UNIQUE,
name VARCHAR(100) NOT NULL,
CONSTRAINT fk_queue_user
FOREIGN KEY (user_id) REFERENCES "User"(id)
ON DELETE CASCADE ON UPDATE CASCADE,
CONSTRAINT chk_queue_name_not_empty CHECK (LENGTH(TRIM(name)) > 0)
);

-- TABULKA: Queue_Song
-- Vazobna tabulka medzi Queue a Song. Realizuje vztah M:N.
-- Skladba sa nemoze v jednej fronte vyskytovat viackrat.
-- Pozicie vo fronte musia byt unikatne (ziadne duplicity poradia).
CREATE TABLE Queue_Song (
id SERIAL PRIMARY KEY,
queue_id INT NOT NULL,
song_id INT NOT NULL,
queue_position INT NOT NULL,
CONSTRAINT fk_qs_queue
FOREIGN KEY (queue_id) REFERENCES Queue(id)
ON DELETE CASCADE ON UPDATE CASCADE,
CONSTRAINT fk_qs_song
FOREIGN KEY (song_id) REFERENCES Song(id)
ON DELETE CASCADE ON UPDATE CASCADE,
-- Skladba sa moze v danej queue nachadzat iba raz
CONSTRAINT uq_queue_song UNIQUE (queue_id, song_id),
-- Pozicia v ramci jednej queue musi byt unikatna
CONSTRAINT uq_queue_position UNIQUE (queue_id, queue_position),
CONSTRAINT chk_queue_position_positive CHECK (queue_position > 0)
);

-- TABULKA: Playlist
-- ZMENA OPROTI ZADANIU 1: Playlist patri priamo pouzivatelovi (nie kniznici).
-- V ramci jedneho pouzivatela musia byt nazvy playlistov unikatne.
CREATE TABLE Playlist (
id SERIAL PRIMARY KEY,
user_id INT NOT NULL,
name VARCHAR(100) NOT NULL,
CONSTRAINT fk_playlist_user FOREIGN KEY (user_id) REFERENCES "User"(id)
ON DELETE CASCADE ON UPDATE CASCADE,
-- Pouzivatel nemoze mat dva playlisty s rovnakym nazvom
CONSTRAINT uq_playlist_user_name UNIQUE (user_id, name),
CONSTRAINT chk_playlist_name_not_empty CHECK (LENGTH(TRIM(name)) > 0)
);

-- TABULKA: Playlist_Song
-- Vazobna tabulka medzi Playlist a Song (M:N).
-- Skladba sa v jednom playliste moze nachadzat iba raz.
CREATE TABLE Playlist_Song (
id SERIAL PRIMARY KEY,
playlist_id INT NOT NULL,
song_id INT NOT NULL,
position INT NOT NULL,
CONSTRAINT fk_ps_playlist FOREIGN KEY (playlist_id) REFERENCES Playlist(id)
ON DELETE CASCADE ON UPDATE CASCADE,
CONSTRAINT fk_ps_song
FOREIGN KEY (song_id) REFERENCES Song(id)
ON DELETE CASCADE ON UPDATE CASCADE,
-- Skladba sa v playliste moze nachadzat iba raz
CONSTRAINT uq_playlist_song UNIQUE (playlist_id, song_id),
-- Pozicia v ramci jedneho playlistu musi byt unikatna
CONSTRAINT uq_playlist_position UNIQUE (playlist_id, position),
CONSTRAINT chk_playlist_position_positive CHECK (position > 0)
);