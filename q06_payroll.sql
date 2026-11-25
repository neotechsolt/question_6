-- Q6 Monthly Payroll Processing (PostgreSQL)

-- (a) Tables
CREATE TABLE employees (
    employee_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL,
    basic_salary DECIMAL(12, 2) NOT NULL CHECK (basic_salary >= 0),
    allowance DECIMAL(12, 2) NOT NULL CHECK (allowance >= 0),
    deduction DECIMAL(12, 2) NOT NULL CHECK (deduction >= 0),
    active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    pay_month DATE NOT NULL CHECK (pay_month = DATE_TRUNC('month', pay_month)::DATE),
    gross_pay DECIMAL(12, 2) NOT NULL,
    net_pay DECIMAL(12, 2) NOT NULL,
    UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    old_salary DECIMAL(12, 2) NOT NULL,
    new_salary DECIMAL(12, 2) NOT NULL,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction) VALUES
('Alice Mwape', 8000, 1500, 1200),
('Brian Chilufya', 6500, 1000, 900),
('Catherine Njovu', 9500, 2000, 1800),
('Daniel Mutale', 5000, 500, 600),
('Eunice Kasonde', 7000, 1200, 1000);

-- (b) Function
CREATE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS DECIMAL AS $$
DECLARE v_net DECIMAL(12, 2);
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
    FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Employee % does not exist', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Net pay for employee % is negative', p_employee_id;
    END IF;
    RETURN v_net;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure
CREATE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE rec RECORD;
BEGIN
    IF p_month IS NULL OR p_month <> DATE_TRUNC('month', p_month)::DATE THEN
        RAISE EXCEPTION 'Month must be the first day of a month';
    END IF;

    FOR rec IN SELECT employee_id, basic_salary, allowance FROM employees WHERE active LOOP
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, rec.basic_salary + rec.allowance, fn_net_pay(rec.employee_id))
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- (d) Trigger
CREATE FUNCTION trg_salary_audit() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_employees_update
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_salary_audit();

-- (a) Two payroll months (employee 5 leaves between them)
CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '2 months')::DATE);
UPDATE employees SET active = FALSE WHERE employee_id = 5;
CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE);

-- running a month again changes nothing
CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE);

-- trigger check
UPDATE employees SET basic_salary = basic_salary + 500 WHERE employee_id = 1;  -- logged
UPDATE employees SET allowance = allowance + 100 WHERE employee_id = 1;        -- not logged
SELECT * FROM salary_audit;

-- (e) View (inner join keeps history of inactive employees)
CREATE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) Index (the unique index starts with employee_id, so it cannot help a pay_month search)
CREATE INDEX idx_payroll_month ON payroll (pay_month);

EXPLAIN SELECT * FROM payroll
WHERE pay_month = (DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE;

-- (g) Scheduled job
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('monthly_payroll', '0 2 1 * *',
    $$CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE)$$);

-- check the job and its history
SELECT jobid, jobname, schedule, command, active FROM cron.job;
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details ORDER BY start_time DESC;
