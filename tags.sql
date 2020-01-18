CREATE TABLE IF NOT EXISTS tags (
  id INTEGER PRIMARY KEY AUTOINCREMENT, date TEXT, nick TEXT, userhost TEXT,
  tag TEXT UNIQUE COLLATE NOCASE, message TEXT NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS tags_fts USING fts5 (
  id UNINDEXED, date UNINDEXED, nick UNINDEXED, userhost UNINDEXED,
  tag, message, content=tags, content_rowid=id
);

CREATE INDEX IF NOT EXISTS idx_tags_tag ON tags(tag);
CREATE INDEX IF NOT EXISTS idx_tags_nick ON tags(nick);

CREATE TRIGGER IF NOT EXISTS tags_bu BEFORE UPDATE ON tags BEGIN
  DELETE FROM tags_fts WHERE rowid=old.id;
END;
CREATE TRIGGER IF NOT EXISTS tags_bd BEFORE DELETE ON tags BEGIN
  DELETE FROM tags_fts WHERE rowid=old.id;
END;
CREATE TRIGGER IF NOT EXISTS tags_au AFTER UPDATE ON tags BEGIN
  INSERT INTO tags_fts (rowid, tag, message) VALUES (new.id, new.tag, new.message);
END;
CREATE TRIGGER IF NOT EXISTS tags_ai AFTER INSERT ON tags BEGIN
  INSERT INTO tags_fts (rowid, tag, message) VALUES (new.id, new.tag, new.message);
END;
