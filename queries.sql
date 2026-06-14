-- Pohlady (VIEW) pouzivane v procesoch


-- VIEW: v_user_queue
-- Pouzitie: Proces 1
-- Zobrazi aktualny obsah queue daneho pouzivatela zoradeny podla pozicie.
-- Spaja Queue, Queue_Song, Song a User (autora) - aplikacia tak nemusi
-- pri kazdom pohlade na queue robit tieto JOINy znova.
DROP VIEW IF EXISTS v_user_queue CASCADE;
CREATE VIEW v_user_queue AS
SELECT
q.user_id,
q.id AS queue_id,
qs.id AS queue_song_id,
qs.song_id,
s.name AS song_name,
u.name AS author_name,
s.duration,
qs.queue_position
FROM Queue q
LEFT JOIN Queue_Song qs ON qs.queue_id = q.id
LEFT JOIN Song s ON s.id = qs.song_id
LEFT JOIN "User" u ON u.id = s.author_id;

-- VIEW: v_song_popularity
-- Pouzitie: Proces 2
-- Popularita skladby = pocet jej vyskytov vo vsetkych playlistoch.
-- Tato metrika je zakladom oboch analytickych dopytov v Procese 2.
-- LEFT JOIN zaruci, ze aj skladby ktore nie su v ziadnom playliste budu
-- mat playlist_count = 0 (a nie ze v rebricku chybali).
DROP VIEW IF EXISTS v_song_popularity CASCADE;
CREATE VIEW v_song_popularity AS
SELECT
s.id AS song_id,
s.name AS song_name,
s.author_id,
s.duration,
s.is_approved,
COUNT(ps.id) AS playlist_count
FROM Song s
LEFT JOIN Playlist_Song ps ON ps.song_id = s.id
GROUP BY s.id;


-- VIEW: v_artist_stats
-- Pouzitie: Proces 2
-- Pre kazdeho artistu agreguje:
--   * total_songs        - pocet schvalenych skladieb
--   * total_appearances  - sumarny pocet vyskytov vo vsetkych playlistoch
--   * avg_popularity     - priemerna popularita jeho skladby
--   * top_song_pop       - popularita jeho najuspesnejsej skladby
--
-- Pohlad NEFILTRUJE artistov s malo skladbami - to robi az dopyt v procese.
DROP VIEW IF EXISTS v_artist_stats CASCADE;
CREATE VIEW v_artist_stats AS
SELECT
u.id AS artist_id,
u.name AS artist_name,
COUNT(sp.song_id) AS total_songs,
COALESCE(SUM(sp.playlist_count), 0) AS total_appearances,
COALESCE(ROUND(AVG(sp.playlist_count), 2), 0) AS avg_popularity,
COALESCE(MAX(sp.playlist_count), 0) AS top_song_pop
FROM "User" u
JOIN Role r ON r.id = u.role_id
LEFT JOIN v_song_popularity sp ON sp.author_id = u.id AND sp.is_approved = TRUE
WHERE r.name = 'ARTIST'
GROUP BY u.id, u.name;


-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- Vlastne indexy podporujuce Proces 1 a Proces 2
-- Spustenie:   psql -d <dbname> -f indexes.sql
-- Postgres automaticky vytvara B-tree indexy pre PRIMARY KEY
-- a UNIQUE obmedzenia. Tieto indexy SU UZ K DISPOZICII zo schema.sql:
--   * Queue.user_id            (UNIQUE -> automaticky index)
--   * Queue_Song.queue_id+queue_position  (UNIQUE -> automaticky)
--   * Queue_Song.queue_id+song_id          (UNIQUE -> automaticky)
--   * Playlist_Song.playlist_id+song_id    (UNIQUE -> automaticky)
--   * Playlist_Song.playlist_id+position   (UNIQUE -> automaticky)
--   * "User".email                         (UNIQUE -> automaticky)
--
-- Tu pridavame DALSIE 3 vlastne indexy nad ramec automaticky vytvorenych.

-- INDEX 1: idx_playlist_song_song_id
-- Pre Proces 2 (analyticky)
-- Podporuje: view v_song_popularity, ktory robi
-- LEFT JOIN Playlist_Song ps ON ps.song_id = s.id
-- GROUP BY s.id
-- Bez tohto indexu Postgres robi sequential scan cez Playlist_Song (~23k
-- riadkov) a hash agregaciu. S indexom moze pouzit index-only scan a hash
-- agreacia bezi na uz zoskupenych datach.

-- Pozn: UNIQUE (playlist_id, song_id) ma song_id az ako druhy stlpec, takze
-- tento composite index NIE JE pouzitelny pre lookup po samotnom song_id.
DROP INDEX IF EXISTS idx_playlist_song_song_id;
CREATE INDEX idx_playlist_song_song_id ON Playlist_Song (song_id);


-- INDEX 2: idx_song_author_approved (PARTIAL INDEX)
-- Pre Proces 2 (analyticky)
-- Podporuje:  WHERE s.is_approved = TRUE  + GROUP BY author_id
-- Partial index pokryva LEN schvalene skladby (~85 % datasetu).
-- Vyhody:
--   * mensi rozmerom -> rychlejsi v RAM
--   * Postgres ho moze pouzit aj na index-only scan
--   * sucasne pomahae filtru is_approved aj groupingu/joinu po author_id
-- Toto je idealny use-case pre partial index, kedze Proces 2 vzdy filtruje
-- iba na schvalene skladby.
DROP INDEX IF EXISTS idx_song_author_approved;
CREATE INDEX idx_song_author_approved
    ON Song (author_id)
    WHERE is_approved = TRUE;


-- INDEX 3: idx_user_role_id
-- Pre Proces 2 (analyticky)
-- Podporuje:  filter "WHERE r.name = 'ARTIST'" v Procese 2.
-- Filter cez JOIN sa redukuje na "User WHERE role_id = (artistovo_id)".
-- Bez indexu -> sequential scan cez 2000 userov.
-- S indexom -> bitmap heap scan po liste artistov.
-- Pri buducom raste systemu (200k+ userov) je tento index kriticky.
DROP INDEX IF EXISTS idx_user_role_id;
CREATE INDEX idx_user_role_id ON "User" (role_id);


-- Pridane vlastne indexy:
--   1. idx_playlist_song_song_id   (Playlist_Song.song_id)
--   2. idx_song_author_approved    (Song.author_id WHERE is_approved=TRUE)
--   3. idx_user_role_id            ("User".role_id)
--
-- Overenie ze indexy existuju:
-- SELECT indexname FROM pg_indexes
--   WHERE schemaname = 'public' AND indexname LIKE 'idx_%'
--   ORDER BY indexname;



-- Vystup s explain do reportu najpr bez, potom s indexom:
 DROP INDEX idx_playlist_song_song_id;
 EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM v_song_popularity 
 ORDER BY playlist_count DESC LIMIT 20;
 CREATE INDEX idx_playlist_song_song_id ON Playlist_Song(song_id);
 EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM v_song_popularity 
 ORDER BY playlist_count DESC LIMIT 20;

-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- Proces 1: Sprava queue

-- Proces zodpoveda Scenaru 4 zo Zadania 1 ("Sprava queue") a obsahuje
-- 3 operacie: pridanie skladby, zmena poradia, odstranenie skladby.

--   Tento blok najde pouzivatela s 5-7 skladbami v queue a vypise jeho
--   ID + meno + queue_id. Toto ID bude 4 pre ukazku
SELECT
q.user_id,
u.name AS meno,
u.email,
r.name AS rola,
q.idAS queue_id,
COUNT(qs.id)AS pocet_skladieb_v_queue
FROM Queue q
JOIN "User" u   ON u.id = q.user_id
JOIN Role r ON r.id = u.role_id
LEFT JOIN Queue_Song qs ON qs.queue_id = q.id
GROUP BY q.user_id, u.name, u.email, r.name, q.id
HAVING COUNT(qs.id) BETWEEN 5 AND 7
ORDER BY q.user_id
LIMIT 1;

-- Pociatocny stav queue
SELECT v.queue_position AS poz, v.song_id, v.song_name, v.author_name, v.duration
FROM v_user_queue v
WHERE v.user_id = 4
ORDER BY v.queue_position;

-- Pridanie skladby na koniec queue
-- Najprv si pozrieme, ktoru skladbu pridame (prva schvalena ktora
-- este nie je v queue daneho usera, bude to 1)
SELECT s.id AS song_id_na_pridanie, s.name AS song_name, s.duration
FROM Song s
WHERE s.is_approved = TRUE AND NOT EXISTS (
SELECT 1 FROM Queue_Song qs
JOIN Queue q ON q.id = qs.queue_id
WHERE q.user_id = 4
AND qs.song_id = s.id)
ORDER BY s.id
LIMIT 1;

-- Vykonavame INSERT (skladba ide na pos = MAX(pos) + 1)
INSERT INTO Queue_Song (queue_id, song_id, queue_position)
SELECT q.id, s.id,
COALESCE((SELECT MAX(queue_position) FROM Queue_Song WHERE queue_id = q.id), 0) + 1
FROM Queue q
CROSS JOIN Song s
WHERE q.user_id = 4 AND s.is_approved = TRUE AND s.id = (
SELECT s2.id FROM Song s2 WHERE s2.is_approved = TRUE
AND NOT EXISTS (
SELECT 1 FROM Queue_Song qs
JOIN Queue q2 ON q2.id = qs.queue_id
WHERE q2.user_id = 4 AND qs.song_id = s2.id
)ORDER BY s2.id LIMIT 1);

-- Stav po pridani - skladba je na novej najvyssej pozicii
SELECT v.queue_position AS poz, v.song_id, v.song_name
FROM v_user_queue v
WHERE v.user_id = 4
ORDER BY v.queue_position;

-- ----------------------------------------------------------------------
-- 2. ZMENA PORADIA
--  Krok 1   - presuvana skladba ide na docasnu poziciu 999999
--  Krok 2a  - ostatne skladby v rozsahu posunieme o +1000000 (uvolnenie)
--  Krok 2b  - vratime ich spat s posunom o +1
--  Krok 3   - presuvana skladba ide na finalnu poziciu 2

-- Stav pred zmenou
SELECT v.queue_position AS poz, v.song_id, v.song_name
FROM v_user_queue v
WHERE v.user_id = 4
ORDER BY v.queue_position;

-- Krok 1: presuvana skladba (z najvyssej pozicie) ide na 999999
UPDATE Queue_Song
SET queue_position = 999999
WHERE queue_id = (SELECT id FROM Queue WHERE user_id = 4) AND queue_position = (
SELECT MAX(queue_position) FROM Queue_Song
WHERE queue_id = (SELECT id FROM Queue WHERE user_id = 4)
AND queue_position < 999999);

-- Krok 2a: ostatne skladby z rozsahu [2, max-1] posun o +1000000
UPDATE Queue_Song
SET queue_position = queue_position + 1000000
WHERE queue_id = (SELECT id FROM Queue WHERE user_id = 4)
AND queue_position >= 2
AND queue_position < 999999;

-- KROK 2b: vrat ich spat na pozicie [3, max] (smer HORE -> +1)
UPDATE Queue_Song
SET queue_position = queue_position - 1000000 + 1
WHERE queue_id = (SELECT id FROM Queue WHERE user_id = 4)
AND queue_position > 1000000;

-- KROK 3: presuvana skladba (na 999999) ide na poziciu 2
UPDATE Queue_Song
SET queue_position = 2
WHERE queue_id = (SELECT id FROM Queue WHERE user_id = 4)
AND queue_position = 999999;

-- Stav po zmene poradia
SELECT v.queue_position AS poz, v.song_id, v.song_name
FROM v_user_queue v
WHERE v.user_id = 4
ORDER BY v.queue_position;

-- ----------------------------------------------------------------------
-- Odstranenie skladby z 3tej pozicie
-- Stav pred odstranenim
SELECT v.queue_position AS poz, v.song_id, v.song_name
FROM v_user_queue v
WHERE v.user_id = 4
ORDER BY v.queue_position;

-- DELETE skladby na pozicii 3
DELETE FROM Queue_Song
WHERE queue_id = (SELECT id FROM Queue WHERE user_id = 4)
AND queue_position = 3;

-- Stav po delete vidno medzeru (chyba pozicia 3, ale je pos 4, 5, ...)
SELECT v.queue_position AS poz, v.song_id, v.song_name
FROM v_user_queue v
WHERE v.user_id = 4
ORDER BY v.queue_position;

-- Zacelenie medzery: pozicie > 3 sa znizia o 1
UPDATE Queue_Song
SET queue_position = queue_position - 1
WHERE queue_id = (SELECT id FROM Queue WHERE user_id = 4)
AND queue_position > 3;

-- Stav po zaceleni
SELECT v.queue_position AS poz, v.song_id, v.song_name
FROM v_user_queue v
WHERE v.user_id = 4
ORDER BY v.queue_position;

-- Pre reset treba znova spustit seed.sql
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
-- Proces 2: Rebricek najpopularnejsich skladieb a artistov

-- Proces obsahuje:
-- 1) TOP 20 najpopularnejsich skladieb (s rankingom)
-- 2) Rebricek artistov podla priemernej popularity ich skladieb
-- 3) Identifikacia "one-hit wonders" pomocou window functions


-- 1. TOP 20 najpopularnejsich skladieb
-- Popularita = pocet playlistov v ktorych sa skladba nachadza.
-- DENSE_RANK pouzity zamerne aby skladby s rovnakym poctom dostali
-- rovnake poradie (napr. dve skladby v 30 playlistoch = obe rank 1, dalsia = rank 2, nie rank 3).
-- Filter:  iba schvalene skladby s aspon 1 vyskytom v playliste.
WITH ranked_songs AS (
SELECT sp.song_id,
sp.song_name,
u.name AS author_name,
sp.duration AS duration_sec,
sp.playlist_count,
DENSE_RANK() OVER (ORDER BY sp.playlist_count DESC) AS popularity_rank
FROM v_song_popularity sp
JOIN "User" u ON u.id = sp.author_id
WHERE sp.is_approved = TRUE AND sp.playlist_count > 0
)
SELECT
popularity_rank AS rnk,
song_name,
author_name,
duration_sec,
playlist_countAS v_kolkych_playlistoch
FROM ranked_songs
WHERE popularity_rank <= 20
ORDER BY popularity_rank, song_name;


--   Pre TOP 1 skladbu z rebricka manualne (mimo VIEW) spocitame, v kolkych
--   playlistoch sa naozaj nachadza, a porovnaame s hodnotou z rebricka.
--   Stlpec "dokaz" musi byt 'OK - hodnoty sa zhoduju'.
WITH top_song AS (
SELECT sp.song_id, sp.song_name, sp.playlist_count
FROM v_song_popularity sp
WHERE sp.is_approved = TRUE
ORDER BY sp.playlist_count DESC, sp.song_id
LIMIT 1
)
SELECT
ts.song_id,
ts.song_name,
ts.playlist_count AS pocet_z_view,
(SELECT COUNT(*) FROM Playlist_Song ps
 WHERE ps.song_id = ts.song_id)   AS pocet_priamym_count,
CASE WHEN ts.playlist_count = (SELECT COUNT(*) FROM Playlist_Song ps WHERE ps.song_id = ts.song_id) THEN 'OK - hodnoty sa zhoduju' ELSE 'CHYBA' END AS dokaz
FROM top_song ts;

-- -----------------------------------------------------------------------------------------
-- 2. Rebricek artistov podla priemernej popularity ich skladieb
-- Pre kazdeho artistu pocitame:
-- total_songs- kolko ma schvalenych skladieb
-- total_appearances  - sumarny pocet vyskytov v playlistoch
-- avg_popularity - priemerny pocet vyskytov per skladba (Hlavna metrika)
-- HAVING total_songs >= 3:
-- bez tohto filtra by artist s 1 mega-popularnou skladbou prebil
-- ostatnych s konzistentnym priemerom. Filter eliminuje statisticky sum.
-- Vystup obsahuje DVA RANKY (dve window functions DENSE_RANK):
-- rank_by_avg - ako konzistentne dobry je
-- rank_by_total   - ako velky je objemom (sumarne vyskyty)
-- Rozdiel medzi nimi ukazuje povahu artistu (kvalita vs. kvantita).
WITH ranked_artists AS (
SELECT artist_id,
artist_name,
total_songs,
total_appearances,
avg_popularity,
DENSE_RANK() OVER (ORDER BY avg_popularity DESC)AS rank_by_avg,
DENSE_RANK() OVER (ORDER BY total_appearances DESC) AS rank_by_total
FROM v_artist_stats
WHERE total_songs >= 3
)
SELECT
rank_by_avg AS rnk,
artist_name,
total_songs AS pocet_skladieb,
total_appearances AS celkovo_vyskytov,
avg_popularityAS priemer_vyskytov,
rank_by_total AS rnk_celkovym_objemom
FROM ranked_artists
WHERE rank_by_avg <= 20
ORDER BY rank_by_avg, artist_name;

--   Pre TOP 1 artistu rucne (bez VIEW) spocitame priemer popularity skladieb a porovname s hodnotou v rebricku.
WITH top_artist AS (
SELECT artist_id, artist_name, avg_popularity, total_songs
FROM v_artist_stats
WHERE total_songs >= 3
ORDER BY avg_popularity DESC, artist_name
LIMIT 1
)
SELECT
ta.artist_id,
ta.artist_name,
ta.total_songs AS pocet_skladieb,
ta.avg_popularity AS priemer_z_view,
(SELECT ROUND(AVG(playlist_count)::numeric, 2)
FROM v_song_popularity sp
WHERE sp.author_id = ta.artist_id AND sp.is_approved = TRUE) AS priemer_rucne,
CASE WHEN ta.avg_popularity = (SELECT ROUND(AVG(playlist_count)::numeric, 2)
FROM v_song_popularity sp
WHERE sp.author_id = ta.artist_id AND sp.is_approved = TRUE) THEN 'OK - hodnoty sa zhoduju' ELSE 'CHYBA' END AS dokaz
FROM top_artist ta;

--   Doplnujuca info o tom, kolko artistov spada do rebricka
SELECT
COUNT(*) FILTER (WHERE total_songs >= 3) AS s_aspon_3_skladbami,
COUNT(*) FILTER (WHERE total_songs <  3 AND total_songs > 0) AS s_menej_ako_3_skladbami,
COUNT(*) FILTER (WHERE total_songs = 0)  AS bez_schvalenych_skladieb,
COUNT(*) AS celkovo_artistov
FROM v_artist_stats;
-- -----------------------------------------------------------------------------------------
-- 3. Top 10 one-hit wonders
-- Hladame TOP 10 artistov, u ktorych je rozdiel medzi top skladbou a
-- priemerom najvacsi. Su to artisti, ktori maju jednu vyrazne popularnu
-- skladbu a zvysok priemerne ci slabsie - klasicky "one-hit wonder" profil.
-- Pridana metrika "pomer_rozdielu" = (top - priemer) / top, vyjadrena
-- v percentach. Vyjadruje, akou mierou top skladba dominuje nad priemerom
SELECT
artist_name,
total_songs AS pocet_skladieb,
top_song_pop AS top_skladba_vyskytov,
avg_popularity AS priemer,
ROUND((top_song_pop - avg_popularity), 2) AS rozdiel,
ROUND(((top_song_pop - avg_popularity) / NULLIF(top_song_pop, 0) * 100)::numeric, 1) AS pomer_rozdielu_percent
FROM v_artist_stats
WHERE total_songs >= 3 AND top_song_pop > 0
ORDER BY (top_song_pop - avg_popularity) DESC, artist_name
LIMIT 10;



