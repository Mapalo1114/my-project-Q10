-- ICT371 Question 10: Scholarship Application Assessment (PostgreSQL)
DROP SCHEMA IF EXISTS q10 CASCADE;
CREATE SCHEMA q10;
SET search_path TO q10, public;

-- (a) TABLES -------------------------------------------------------------
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
  application_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id         INT NOT NULL REFERENCES students(student_id),
  age_at_application INT NOT NULL CHECK (age_at_application > 0),
  monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
  average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
  submitted_on       DATE NOT NULL,
  status             VARCHAR(10) NOT NULL DEFAULT 'PENDING',
  CONSTRAINT chk_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
  audit_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  application_id INT NOT NULL REFERENCES applications(application_id),
  old_status     VARCHAR(10) NOT NULL,
  new_status     VARCHAR(10) NOT NULL,
  changed_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- (b) FUNCTION -----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
  IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
    RAISE EXCEPTION 'Age, income and mark are all required';
  END IF;
  IF p_age <= 0 THEN
    RAISE EXCEPTION 'Age must be positive, got %', p_age;
  END IF;
  IF p_income < 0 THEN
    RAISE EXCEPTION 'Income cannot be negative, got %', p_income;
  END IF;
  IF p_mark < 0 OR p_mark > 100 THEN
    RAISE EXCEPTION 'Mark must be between 0 and 100, got %', p_mark;
  END IF;

  RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- (c) PROCEDURE ----------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
AS $$
DECLARE
  v_status   VARCHAR(10);
  v_age      INT;
  v_income   NUMERIC;
  v_mark     NUMERIC;
  v_eligible BOOLEAN;
BEGIN
  SELECT status, age_at_application, monthly_income, average_mark
  INTO v_status, v_age, v_income, v_mark
  FROM applications WHERE application_id = p_application_id FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown application: %', p_application_id;
  END IF;
  IF v_status <> 'PENDING' THEN
    RAISE EXCEPTION 'Application % has already been assessed (status %)', p_application_id, v_status;
  END IF;

  v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);

  UPDATE applications
  SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
  WHERE application_id = p_application_id;
END;
$$ LANGUAGE plpgsql;

-- (d) TRIGGER ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_decision_audit() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
  VALUES (OLD.application_id, OLD.status, NEW.status, now());
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- (g) PROCEDURE: assess every pending application ------------------------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
AS $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN SELECT application_id FROM applications WHERE status = 'PENDING' ORDER BY application_id
  LOOP
    CALL pr_assess_application(r.application_id);
  END LOOP;
  -- completed applications are never selected, so reruns do nothing and add no audit rows
END;
$$ LANGUAGE plpgsql;

-- (a) SEED DATA: six PENDING applications --------------------------------
INSERT INTO students (student_number, full_name) VALUES
  ('2024201', 'Bupe Chilufya'), ('2024202', 'Namukolo Hamoonga'), ('2024203', 'Kennedy Lungu');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
  (1, 20, 2000.00, 80.00, DATE '2026-11-01'),   -- qualifies
  (1, 17, 1000.00, 90.00, DATE '2026-11-03'),   -- fails: age 17
  (2, 18, 3000.00, 70.00, DATE '2026-11-05'),   -- boundary: qualifies (all limits exact)
  (2, 25, 3001.00, 85.00, DATE '2026-11-08'),   -- fails: income just above K3,000
  (3, 26, 1500.00, 75.00, DATE '2026-11-10'),   -- fails: age 26
  (3, 25, 3000.00, 69.99, DATE '2026-11-12');   -- fails: mark just below 70

SELECT * FROM applications ORDER BY application_id;

-- tests
-- SELECT fn_scholarship_eligible(18, 3000, 70);    -- true  (boundaries)
-- SELECT fn_scholarship_eligible(26, 1000, 90);    -- false
-- SELECT fn_scholarship_eligible(NULL, 1, 1);      -- error
-- SELECT fn_scholarship_eligible(20, -5, 80);      -- error
-- SELECT fn_scholarship_eligible(20, 1000, 101);   -- error
CALL pr_assess_application(1);                       -- APPROVED
-- CALL pr_assess_application(1);                    -- error: already assessed
-- CALL pr_assess_application(99);                   -- error: unknown

CALL pr_assess_pending();                            -- assesses the remaining five
CALL pr_assess_pending();                            -- rerun: nothing changes

SELECT * FROM applications ORDER BY application_id;
SELECT * FROM decision_audit ORDER BY audit_id;      -- exactly 6 audit rows

-- (e) VIEW ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';          -- household income is not exposed

SELECT * FROM v_approved_applicants;

-- (f) INDEX --------------------------------------------------------------
-- Equality on status first, range on submitted_on second.
CREATE INDEX idx_app_status_submitted ON applications (status, submitted_on);

ANALYZE applications;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM applications
WHERE status = 'REJECTED' AND submitted_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';
RESET enable_seqscan;

-- (g) SCHEDULE: every Monday at 08:00 ------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q10_assess_pending', '0 8 * * 1',
  $$CALL q10.pr_assess_pending()$$);
