ALTER TABLE choices ADD COLUMN ord INTEGER NOT NULL DEFAULT 0;

UPDATE choices SET ord = (
    SELECT COUNT(*) FROM choices c2
    WHERE c2.source_step_id = choices.source_step_id
    AND c2.id < choices.id
);
