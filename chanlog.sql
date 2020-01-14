CREATE TABLE IF NOT EXISTS log (
  id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT NOT NULL,
  flag TEXT, nick TEXT NOT NULL, userhost TEXT, handle TEXT,
  message TEXT NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS log_fts USING fts5(
  id UNINDEXED, date UNINDEXED, flag UNINDEXED,
  nick UNINDEXED, userhost UNINDEXED, handle UNINDEXED,
  message, content=log, content_rowid=id
);

CREATE TABLE IF NOT EXISTS tags (
  id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT,
  nick TEXT, userhost TEXT, handle TEXT, channel TEXT,
  tag TEXT UNIQUE, message TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS nicknames(
  nick TEXT NOT NULL PRIMARY KEY COLLATE NOCASE
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS words (
  nick TEXT COLLATE NOCASE, word TEXT COLLATE NOCASE, messageId INT
);
CREATE TABLE IF NOT EXISTS ignorelist (
  word TEXT NOT NULL PRIMARY KEY COLLATE NOCASE
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS idx_log_nick ON log(nick);
CREATE INDEX IF NOT EXISTS idx_log_date ON log(date);

CREATE TRIGGER IF NOT EXISTS log_bu BEFORE UPDATE ON log BEGIN
  DELETE FROM log_fts WHERE rowid=old.id;
END;
CREATE TRIGGER IF NOT EXISTS log_bd BEFORE DELETE ON log BEGIN
  DELETE FROM log_fts WHERE rowid=old.id;
END;
CREATE TRIGGER IF NOT EXISTS log_au AFTER UPDATE ON log BEGIN
  INSERT INTO log_fts(rowid, message) VALUES(new.id, new.message);
END;
CREATE TRIGGER IF NOT EXISTS log_ai AFTER INSERT ON log BEGIN
  INSERT INTO log_fts(rowid, message) VALUES(new.id, new.message);
END;
CREATE TRIGGER IF NOT EXISTS log_bi BEFORE INSERT ON log BEGIN
  INSERT OR IGNORE INTO nicknames (nick) VALUES(new.nick);
END;


INSERT INTO words (nick, word, messageId) VALUES (new.nick, word, new.id)
SELECT REGEX_REPLACE('^[\s“”‘’ -/:-@[-`{-~]+|[\s“”‘’ -/:-@[-`{-~]+$', word, '') FROM word;
