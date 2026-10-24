-- =====================================================================
--  LIBRARY MANAGEMENT SYSTEM  (pure MySQL 8.0+)
--  Run:  mysql -u root -p < library_management.sql
--  Covers: schema, constraints, indexes, triggers, stored procedures,
--          function, views, scheduled event, sample data, test queries
-- =====================================================================

DROP DATABASE IF EXISTS library_db;
CREATE DATABASE library_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE library_db;

-- ---------------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------------
CREATE TABLE categories (
    category_id INT AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(60) NOT NULL UNIQUE
) ENGINE=InnoDB;

CREATE TABLE authors (
    author_id INT AUTO_INCREMENT PRIMARY KEY,
    name      VARCHAR(100) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE publishers (
    publisher_id INT AUTO_INCREMENT PRIMARY KEY,
    name         VARCHAR(100) NOT NULL UNIQUE
) ENGINE=InnoDB;

CREATE TABLE books (
    book_id          INT AUTO_INCREMENT PRIMARY KEY,
    isbn             CHAR(13)     NOT NULL UNIQUE,
    title            VARCHAR(200) NOT NULL,
    category_id      INT          NOT NULL,
    publisher_id     INT          NOT NULL,
    publish_year     YEAR,
    total_copies     INT          NOT NULL DEFAULT 1,
    available_copies INT          NOT NULL DEFAULT 1,
    CONSTRAINT chk_copies CHECK (
        total_copies >= 0 AND available_copies >= 0
        AND available_copies <= total_copies),
    CONSTRAINT fk_book_cat FOREIGN KEY (category_id)  REFERENCES categories(category_id),
    CONSTRAINT fk_book_pub FOREIGN KEY (publisher_id) REFERENCES publishers(publisher_id),
    INDEX idx_title (title),
    INDEX idx_category (category_id)
) ENGINE=InnoDB;

-- many-to-many: a book can have many authors
CREATE TABLE book_authors (
    book_id   INT NOT NULL,
    author_id INT NOT NULL,
    PRIMARY KEY (book_id, author_id),
    CONSTRAINT fk_ba_book   FOREIGN KEY (book_id)   REFERENCES books(book_id)     ON DELETE CASCADE,
    CONSTRAINT fk_ba_author FOREIGN KEY (author_id) REFERENCES authors(author_id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE members (
    member_id   INT AUTO_INCREMENT PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL,
    email       VARCHAR(120) NOT NULL UNIQUE,
    phone       VARCHAR(15),
    member_type ENUM('Student','Faculty','Public') NOT NULL DEFAULT 'Student',
    join_date   DATE NOT NULL,
    expiry_date DATE NOT NULL,
    status      ENUM('Active','Suspended','Expired') NOT NULL DEFAULT 'Active',
    CONSTRAINT chk_member_dates CHECK (expiry_date > join_date)
) ENGINE=InnoDB;

CREATE TABLE issues (
    issue_id    INT AUTO_INCREMENT PRIMARY KEY,
    book_id     INT  NOT NULL,
    member_id   INT  NOT NULL,
    issue_date  DATE NOT NULL,
    due_date    DATE NOT NULL,
    return_date DATE NULL,
    status      ENUM('Issued','Returned') NOT NULL DEFAULT 'Issued',
    CONSTRAINT chk_issue_dates CHECK (due_date >= issue_date),
    CONSTRAINT fk_issue_book   FOREIGN KEY (book_id)   REFERENCES books(book_id),
    CONSTRAINT fk_issue_member FOREIGN KEY (member_id) REFERENCES members(member_id),
    INDEX idx_issue_member (member_id, return_date),
    INDEX idx_issue_due (due_date)
) ENGINE=InnoDB;

CREATE TABLE fines (
    fine_id  INT AUTO_INCREMENT PRIMARY KEY,
    issue_id INT NOT NULL UNIQUE,
    amount   DECIMAL(8,2) NOT NULL CHECK (amount >= 0),
    paid     BOOLEAN NOT NULL DEFAULT FALSE,
    paid_on  DATE NULL,
    CONSTRAINT fk_fine_issue FOREIGN KEY (issue_id) REFERENCES issues(issue_id)
) ENGINE=InnoDB;

CREATE TABLE reservations (
    reservation_id INT AUTO_INCREMENT PRIMARY KEY,
    book_id        INT NOT NULL,
    member_id      INT NOT NULL,
    reserved_on    DATE NOT NULL,
    status         ENUM('Pending','Fulfilled','Cancelled') NOT NULL DEFAULT 'Pending',
    CONSTRAINT fk_res_book   FOREIGN KEY (book_id)   REFERENCES books(book_id),
    CONSTRAINT fk_res_member FOREIGN KEY (member_id) REFERENCES members(member_id)
) ENGINE=InnoDB;

CREATE TABLE audit_log (
    log_id    INT AUTO_INCREMENT PRIMARY KEY,
    action    VARCHAR(30)  NOT NULL,
    details   VARCHAR(255) NOT NULL,
    logged_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 2. FUNCTION  (fine = Rs. 2 per late day)
-- ---------------------------------------------------------------------
DELIMITER $$

CREATE FUNCTION fn_calc_fine(p_due DATE, p_returned DATE)
RETURNS DECIMAL(8,2)
DETERMINISTIC
BEGIN
    RETURN GREATEST(DATEDIFF(p_returned, p_due), 0) * 2.00;
END$$

-- ---------------------------------------------------------------------
-- 3. TRIGGERS
-- ---------------------------------------------------------------------

-- Validate every new issue (works even for direct INSERTs)
CREATE TRIGGER trg_issue_before_insert
BEFORE INSERT ON issues
FOR EACH ROW
BEGIN
    DECLARE v_status   VARCHAR(10);
    DECLARE v_expiry   DATE;
    DECLARE v_type     VARCHAR(10);
    DECLARE v_avail    INT;
    DECLARE v_active   INT;
    DECLARE v_limit    INT;
    DECLARE v_dup      INT;
    DECLARE v_unpaid   INT;

    SELECT status, expiry_date, member_type
      INTO v_status, v_expiry, v_type
      FROM members WHERE member_id = NEW.member_id;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Member does not exist';
    END IF;
    IF v_status <> 'Active' OR v_expiry < CURDATE() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Membership is not active';
    END IF;

    SELECT available_copies INTO v_avail FROM books WHERE book_id = NEW.book_id;
    IF v_avail IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Book does not exist';
    END IF;
    IF v_avail <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No copies available';
    END IF;

    SET v_limit = CASE v_type WHEN 'Faculty' THEN 5 WHEN 'Student' THEN 3 ELSE 2 END;
    SELECT COUNT(*) INTO v_active
      FROM issues WHERE member_id = NEW.member_id AND return_date IS NULL;
    IF v_active >= v_limit THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Borrowing limit reached';
    END IF;

    SELECT COUNT(*) INTO v_dup
      FROM issues
     WHERE member_id = NEW.member_id AND book_id = NEW.book_id AND return_date IS NULL;
    IF v_dup > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Member already has this book';
    END IF;

    SELECT COUNT(*) INTO v_unpaid
      FROM fines f JOIN issues i ON i.issue_id = f.issue_id
     WHERE i.member_id = NEW.member_id AND f.paid = FALSE;
    IF v_unpaid > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Clear unpaid fines first';
    END IF;
END$$

CREATE TRIGGER trg_issue_after_insert
AFTER INSERT ON issues
FOR EACH ROW
BEGIN
    UPDATE books SET available_copies = available_copies - 1
     WHERE book_id = NEW.book_id;
    INSERT INTO audit_log(action, details)
    VALUES ('ISSUE', CONCAT('Book ', NEW.book_id, ' issued to member ', NEW.member_id));
END$$

CREATE TRIGGER trg_issue_before_update
BEFORE UPDATE ON issues
FOR EACH ROW
BEGIN
    IF OLD.return_date IS NULL AND NEW.return_date IS NOT NULL THEN
        IF NEW.return_date < OLD.issue_date THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Return date before issue date';
        END IF;
        SET NEW.status = 'Returned';
    END IF;
END$$

CREATE TRIGGER trg_issue_after_update
AFTER UPDATE ON issues
FOR EACH ROW
BEGIN
    DECLARE v_fine DECIMAL(8,2);

    IF OLD.return_date IS NULL AND NEW.return_date IS NOT NULL THEN
        UPDATE books SET available_copies = available_copies + 1
         WHERE book_id = NEW.book_id;

        SET v_fine = fn_calc_fine(NEW.due_date, NEW.return_date);
        IF v_fine > 0 THEN
            INSERT INTO fines(issue_id, amount) VALUES (NEW.issue_id, v_fine);
        END IF;

        INSERT INTO audit_log(action, details)
        VALUES ('RETURN', CONCAT('Issue ', NEW.issue_id, ' returned, fine Rs.', v_fine));
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 4. STORED PROCEDURES
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_issue_book(IN p_book_id INT, IN p_member_id INT, IN p_days INT)
BEGIN
    DECLARE v_days INT DEFAULT IFNULL(p_days, 14);
    INSERT INTO issues(book_id, member_id, issue_date, due_date)
    VALUES (p_book_id, p_member_id, CURDATE(), DATE_ADD(CURDATE(), INTERVAL v_days DAY));

    -- fulfil a pending reservation if this member had one
    UPDATE reservations SET status = 'Fulfilled'
     WHERE book_id = p_book_id AND member_id = p_member_id AND status = 'Pending';

    SELECT 'Book issued successfully' AS message,
           DATE_ADD(CURDATE(), INTERVAL v_days DAY) AS due_date;
END$$

CREATE PROCEDURE sp_return_book(IN p_issue_id INT)
BEGIN
    UPDATE issues SET return_date = CURDATE()
     WHERE issue_id = p_issue_id AND return_date IS NULL;

    IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid issue id or already returned';
    END IF;

    SELECT 'Book returned' AS message,
           IFNULL((SELECT amount FROM fines WHERE issue_id = p_issue_id), 0) AS fine_due;
END$$

CREATE PROCEDURE sp_pay_fine(IN p_fine_id INT)
BEGIN
    UPDATE fines SET paid = TRUE, paid_on = CURDATE()
     WHERE fine_id = p_fine_id AND paid = FALSE;
    IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid fine id or already paid';
    END IF;
    SELECT 'Fine paid' AS message;
END$$

CREATE PROCEDURE sp_reserve_book(IN p_book_id INT, IN p_member_id INT)
BEGIN
    DECLARE v_avail INT;
    SELECT available_copies INTO v_avail FROM books WHERE book_id = p_book_id;
    IF v_avail > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Copies are available, issue the book directly';
    END IF;
    INSERT INTO reservations(book_id, member_id, reserved_on)
    VALUES (p_book_id, p_member_id, CURDATE());
    SELECT 'Reservation placed' AS message;
END$$

CREATE PROCEDURE sp_search_books(IN p_keyword VARCHAR(100))
BEGIN
    SELECT b.book_id, b.title, 
           GROUP_CONCAT(a.name SEPARATOR ', ') AS authors,
           c.name AS category, b.available_copies
      FROM books b
      JOIN categories c        ON c.category_id = b.category_id
      LEFT JOIN book_authors ba ON ba.book_id = b.book_id
      LEFT JOIN authors a       ON a.author_id = ba.author_id
     WHERE b.title LIKE CONCAT('%', p_keyword, '%')
        OR a.name  LIKE CONCAT('%', p_keyword, '%')
        OR c.name  LIKE CONCAT('%', p_keyword, '%')
     GROUP BY b.book_id, b.title, c.name, b.available_copies;
END$$

CREATE PROCEDURE sp_member_history(IN p_member_id INT)
BEGIN
    SELECT i.issue_id, b.title, i.issue_date, i.due_date, i.return_date, i.status,
           IFNULL(f.amount, 0) AS fine, IFNULL(f.paid, TRUE) AS fine_paid
      FROM issues i
      JOIN books b      ON b.book_id = i.book_id
      LEFT JOIN fines f ON f.issue_id = i.issue_id
     WHERE i.member_id = p_member_id
     ORDER BY i.issue_date DESC;
END$$

-- ---------------------------------------------------------------------
-- 5. SCHEDULED EVENT  (needs: SET GLOBAL event_scheduler = ON;)
-- ---------------------------------------------------------------------
CREATE EVENT ev_expire_members
ON SCHEDULE EVERY 1 DAY STARTS CURRENT_TIMESTAMP
DO
    UPDATE members SET status = 'Expired'
     WHERE expiry_date < CURDATE() AND status = 'Active'$$

DELIMITER ;

-- ---------------------------------------------------------------------
-- 6. VIEWS
-- ---------------------------------------------------------------------
CREATE VIEW v_available_books AS
SELECT b.book_id, b.title, c.name AS category, b.available_copies, b.total_copies
  FROM books b JOIN categories c ON c.category_id = b.category_id
 WHERE b.available_copies > 0;

CREATE VIEW v_overdue_books AS
SELECT i.issue_id, m.member_id, m.full_name, m.email, b.title, i.due_date,
       DATEDIFF(CURDATE(), i.due_date)                AS days_overdue,
       fn_calc_fine(i.due_date, CURDATE())            AS fine_so_far
  FROM issues i
  JOIN members m ON m.member_id = i.member_id
  JOIN books b   ON b.book_id   = i.book_id
 WHERE i.return_date IS NULL AND i.due_date < CURDATE();

CREATE VIEW v_current_loans AS
SELECT i.issue_id, m.full_name, b.title, i.issue_date, i.due_date
  FROM issues i
  JOIN members m ON m.member_id = i.member_id
  JOIN books b   ON b.book_id   = i.book_id
 WHERE i.return_date IS NULL;

CREATE VIEW v_popular_books AS
SELECT b.book_id, b.title, COUNT(i.issue_id) AS times_issued
  FROM books b LEFT JOIN issues i ON i.book_id = b.book_id
 GROUP BY b.book_id, b.title
 ORDER BY times_issued DESC;

CREATE VIEW v_unpaid_fines AS
SELECT f.fine_id, m.full_name, b.title, f.amount
  FROM fines f
  JOIN issues i  ON i.issue_id  = f.issue_id
  JOIN members m ON m.member_id = i.member_id
  JOIN books b   ON b.book_id   = i.book_id
 WHERE f.paid = FALSE;

-- ---------------------------------------------------------------------
-- 7. SAMPLE DATA
-- ---------------------------------------------------------------------
INSERT INTO categories(name) VALUES
 ('Computer Science'),('Electronics'),('Mathematics'),('Fiction'),('Physics');

INSERT INTO publishers(name) VALUES
 ('McGraw Hill'),('Pearson'),('Oxford University Press'),('PHI Learning'),('Penguin');

INSERT INTO authors(name) VALUES
 ('Abraham Silberschatz'),('Henry F. Korth'),('S. Sudarshan'),
 ('Thomas H. Cormen'),('Charles E. Leiserson'),
 ('Behzad Razavi'),('Robert L. Boylestad'),
 ('Erwin Kreyszig'),('George Orwell'),('H. C. Verma');

INSERT INTO books(isbn,title,category_id,publisher_id,publish_year,total_copies,available_copies) VALUES
 ('9780078022159','Database System Concepts',1,1,2019,4,4),
 ('9780262033848','Introduction to Algorithms',1,2,2009,3,3),
 ('9780072524932','Design of Analog CMOS Integrated Circuits',2,1,2016,2,2),
 ('9780133782974','Electronic Devices and Circuit Theory',2,2,2013,3,3),
 ('9780470458365','Advanced Engineering Mathematics',3,3,2011,5,5),
 ('9780451524935','1984',4,5,1949,2,2),
 ('9788177091878','Concepts of Physics Vol 1',5,4,2017,3,3);

INSERT INTO book_authors(book_id, author_id) VALUES
 (1,1),(1,2),(1,3),(2,4),(2,5),(3,6),(4,7),(5,8),(6,9),(7,10);

INSERT INTO members(full_name,email,phone,member_type,join_date,expiry_date) VALUES
 ('Aarav Sen',   'aarav@example.com',  '9000000001','Student', CURDATE(), DATE_ADD(CURDATE(), INTERVAL 1 YEAR)),
 ('Diya Roy',    'diya@example.com',   '9000000002','Student', CURDATE(), DATE_ADD(CURDATE(), INTERVAL 1 YEAR)),
 ('Prof. Mehta', 'mehta@example.com',  '9000000003','Faculty', CURDATE(), DATE_ADD(CURDATE(), INTERVAL 2 YEAR)),
 ('Rahul Das',   'rahul@example.com',  '9000000004','Public',  CURDATE(), DATE_ADD(CURDATE(), INTERVAL 6 MONTH));

-- ---------------------------------------------------------------------
-- 8. DEMO / TEST CALLS
-- ---------------------------------------------------------------------
CALL sp_issue_book(1, 1, 14);          -- Aarav borrows DBMS book
CALL sp_issue_book(2, 1, 14);          -- Aarav borrows CLRS
CALL sp_issue_book(5, 3, 30);          -- Prof. Mehta borrows Kreyszig

-- Back-dated loan so you can see overdue + fine logic
INSERT INTO issues(book_id, member_id, issue_date, due_date)
VALUES (6, 2, DATE_SUB(CURDATE(), INTERVAL 25 DAY), DATE_SUB(CURDATE(), INTERVAL 10 DAY));

SELECT * FROM v_overdue_books;         -- Diya's 1984 is 10 days late
CALL sp_return_book(4);                -- returns it -> fine = Rs. 20 created
SELECT * FROM v_unpaid_fines;
CALL sp_pay_fine(1);

CALL sp_search_books('database');
CALL sp_member_history(1);
SELECT * FROM v_available_books;
SELECT * FROM v_current_loans;
SELECT * FROM v_popular_books LIMIT 5;
SELECT * FROM audit_log;

-- Try breaking the rules (each of these should raise an error):
-- CALL sp_issue_book(1, 1, 14);       -- duplicate issue
-- CALL sp_issue_book(3, 4, 14);       -- fine: public member, 1st book OK; try 3 books -> limit error
-- CALL sp_reserve_book(1, 2);         -- copies available -> error

-- Handy report queries
-- Members with most books borrowed
SELECT m.full_name, COUNT(*) AS total_borrowed
  FROM issues i JOIN members m ON m.member_id = i.member_id
 GROUP BY m.member_id, m.full_name
 ORDER BY total_borrowed DESC;

-- Category-wise stock
SELECT c.name, SUM(b.total_copies) AS total, SUM(b.available_copies) AS available
  FROM books b JOIN categories c ON c.category_id = b.category_id
 GROUP BY c.name;
