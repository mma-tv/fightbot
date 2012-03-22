-- fights.sql
-- Loaded by Fight Poll TCL, fights.tcl

PRAGMA count_changes = ON;
PRAGMA foreign_keys = ON;
PRAGMA recursive_triggers = ON;
PRAGMA locking_mode = EXCLUSIVE;
PRAGMA temp_store = MEMORY;


-- !!! IMPORTANT: LEAVE THIS TEMP TABLE ON TOP TO GUARANTEE CREATION !!!
CREATE TEMPORARY TABLE rankings (
	user_id INTEGER NOT NULL,
	nick VARCHAR(64) NOT NULL COLLATE NOCASE,
	wins INTEGER NOT NULL,
	losses INTEGER NOT NULL,
	streak INTEGER NOT NULL,
	rating REAL NOT NULL,
	rank INTEGER NOT NULL
);
CREATE UNIQUE INDEX idx_rankings_user_id ON rankings(user_id);
CREATE UNIQUE INDEX idx_rankings_nick ON rankings(nick);
CREATE INDEX idx_rankings_streak ON rankings(streak DESC);
CREATE INDEX idx_rankings_rank ON rankings(rank);

CREATE TABLE users (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	nick VARCHAR(64) NOT NULL COLLATE NOCASE,
	host VARCHAR(128) NOT NULL COLLATE NOCASE,
	username VARCHAR(256),
	password CHAR(32),
	timezone VARCHAR(64),
	wins INTEGER DEFAULT 0,
	losses INTEGER DEFAULT 0,
	streak INTEGER DEFAULT 0,
	best_streak INTEGER DEFAULT 0,
	best_streak_date DATETIME,
	worst_streak INTEGER DEFAULT 0,
	worst_streak_date DATETIME
);
CREATE UNIQUE INDEX idx_users_nick ON users(nick);
-- CREATE INDEX idx_users_host ON users(host);
-- CREATE UNIQUE INDEX idx_users_nick_host ON users(nick, host);
CREATE INDEX idx_users_streak ON users(streak DESC);

CREATE TABLE events (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	name VARCHAR(128) NOT NULL UNIQUE COLLATE NOCASE,
	start_date DATETIME DEFAULT (DATETIME()),
	locked BOOLEAN DEFAULT 0,
	notes TEXT
);
CREATE INDEX idx_events_name ON events(name);
CREATE INDEX idx_events_start_date ON events(start_date);

CREATE TABLE fights (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	event_id INTEGER NOT NULL,
	fighter1 VARCHAR(128) NOT NULL COLLATE NOCASE,
	fighter2 VARCHAR(128) NOT NULL COLLATE NOCASE,
	fighter1_odds INTEGER,
	fighter2_odds INTEGER,
	result VARCHAR(128) COLLATE NOCASE,
	notes VARCHAR(512),
	start_time DATETIME,
	locked BOOLEAN DEFAULT 0,
	FOREIGN KEY(event_id) REFERENCES events(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE UNIQUE INDEX idx_fights_fighter1_fighter2_event_id ON fights(fighter1, fighter2, event_id);
CREATE INDEX idx_fights_fighter1_fighter2_result ON fights(fighter1, fighter2, result);
CREATE INDEX idx_fights_event_id ON fights(event_id);
CREATE INDEX idx_fights_result ON fights(result);
CREATE INDEX idx_fights_start_time ON fights(start_time);

CREATE TABLE picks (
	user_id INTEGER NOT NULL,
	fight_id INTEGER NOT NULL,
	pick VARCHAR(128) NOT NULL COLLATE NOCASE,
	vote BOOLEAN DEFAULT 1,
	result INTEGER,
	pick_date DATETIME DEFAULT (DATETIME()),
	PRIMARY KEY(user_id, fight_id),
	FOREIGN KEY(fight_id) REFERENCES fights(id) ON DELETE CASCADE ON UPDATE CASCADE,
	FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE
);
CREATE INDEX idx_picks_pick ON picks(pick);


-- rearrange fighters to prevent duplicate rows of A vs B and B vs A
CREATE TRIGGER tr_validate_fighters_on_insert BEFORE INSERT ON fights
FOR EACH ROW BEGIN
	UPDATE fights SET fighter1 = fighter2, fighter1_odds = fighter2_odds,
		fighter2 = fighter1, fighter2_odds = fighter1_odds
		WHERE fighter1 = NEW.fighter2 AND fighter2 = NEW.fighter1
		AND event_id = NEW.event_id;
END;

CREATE TRIGGER tr_update_picks AFTER UPDATE OF result ON fights
FOR EACH ROW BEGIN
	UPDATE picks SET result =
		(CASE WHEN NEW.result IN('#DRAW', '#NC', '#ND') THEN NULL ELSE (pick = NEW.result) END)
		WHERE fight_id = NEW.id;
END;

-- update win/loss/streak stats
CREATE TRIGGER tr_update_stats_on_update AFTER UPDATE OF result ON picks
FOR EACH ROW BEGIN
	UPDATE users SET
		wins   = (SELECT COUNT(*) FROM picks WHERE user_id = id AND result = 1 AND vote = 1),
		losses = (SELECT COUNT(*) FROM picks WHERE user_id = id AND result = 0 AND vote = 1),
		streak = (SELECT STREAK(id, GROUP_CONCAT('{' || strftime('%s', start_time) || ' ' || pick_result || '}', ' '))
			FROM vw_pick_results WHERE user_id = id)
		WHERE id = NEW.user_id;
END;

/*
 * SQLite does not support stored procedures, so this is a lame hack to
 * update the user stats by invoking the tr_update_stats_on_update trigger
 * instead of duplicating code or using a user-defined function in the app.
 */
CREATE TRIGGER tr_update_stats_on_delete BEFORE DELETE ON picks
FOR EACH ROW BEGIN
	UPDATE picks SET result = NULL, vote = 0
		WHERE user_id = OLD.user_id AND fight_id = OLD.fight_id;
END;

-- update streak records
CREATE TRIGGER tr_update_streak_records AFTER UPDATE OF streak ON users
FOR EACH ROW BEGIN
	UPDATE users SET best_streak = streak, best_streak_date = DATETIME()
		WHERE id = NEW.id AND streak > best_streak;
	UPDATE users SET worst_streak = streak, worst_streak_date = DATETIME()
		WHERE id = NEW.id AND streak < worst_streak;
END;


CREATE VIEW vw_pick_results AS
	SELECT user_id, fight_id, event_id, pick, picks.result AS pick_result, start_time
		FROM picks INNER JOIN fights ON fight_id = fights.id WHERE pick_result IS NOT NULL AND vote = 1;

CREATE VIEW vw_fights AS
	SELECT fights.id AS fight_id, event_id, fighter1, fighter2, fighter1_odds, fighter2_odds,
		result, fights.notes AS fight_notes, start_time, fights.locked AS fight_locked,
		events.name AS event_name, events.start_date AS event_start_date, events.locked AS event_locked,
		events.notes AS event_notes FROM fights INNER JOIN events ON fights.event_id = events.id;

CREATE VIEW vw_picks AS
	SELECT nick, user_id, pick, vote, vw_fights.fight_id, fighter1, fighter2, picks.result AS pick_result,
		event_id, event_name, event_start_date, start_time AS fight_start_time FROM vw_fights
		INNER JOIN picks ON picks.fight_id = vw_fights.fight_id INNER JOIN users ON picks.user_id = users.id;

-- Bayesian rating system for rankings
CREATE VIEW vw_rankings AS
	SELECT user_id, (SELECT (MAX(wins + losses) - AVG(wins + losses)) * .75 FROM users) AS avg_num_votes,
	(SELECT MAX(COUNT(*) * .20, 1) FROM fights WHERE result IS NOT NULL) AS min_votes,
	(SELECT AVG(pick_result) FROM vw_pick_results) AS avg_rating, COUNT(user_id) AS this_num_votes,
	AVG(pick_result) AS this_rating FROM vw_pick_results INNER JOIN events ON event_id = events.id
	GROUP BY user_id;

CREATE VIEW vw_stats AS
	SELECT user_id, nick, wins, losses, streak,
	((avg_num_votes * avg_rating) + ((this_num_votes * MIN(this_num_votes / min_votes, 1)) * this_rating))
	/ (avg_num_votes + (this_num_votes * MIN(this_num_votes / min_votes, 1))) AS rating
	FROM users INNER JOIN vw_rankings ON users.id = user_id;
