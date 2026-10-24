# Library Management System

A MySQL-based Library Management System designed to manage books, authors, categories, members, book issues and returns, reservations, and fines.

## Features
- Book inventory and availability tracking
- Member management and borrowing limits
- Book issue and return management
- Automatic fine calculation for overdue books
- Book reservations and search functionality
- Stored procedures, triggers, views, and audit logging
- Popular book and overdue book reports

## Technologies Used
- MySQL 8.0+
- SQL (DDL, DML, joins, subqueries, stored procedures, triggers, and views)

## Setup
1. Install MySQL 8.0 or later.
2. Open MySQL Workbench or your preferred SQL client.
3. Execute `library_management.sql` to create the database, tables, and other database objects.
4. Run the sample queries to test the system.

**Note:** The daily membership-expiry event requires MySQL's event scheduler to be enabled.

## Purpose
This project demonstrates practical DBMS concepts, relational database design, data integrity, and SQL-based library operations.
