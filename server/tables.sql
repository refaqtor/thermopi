
DROP TABLE sensors;

CREATE TABLE IF NOT EXISTS sensors (
 id integer NOT NULL PRIMARY KEY,
 name varchar(256) NOT NULL
);

INSERT INTO sensors (id, name) values (1, 'Living Room');
INSERT INTO sensors (id, name) values (2, 'Garage');

DROP TABLE sensor_data;

CREATE TABLE IF NOT EXISTS sensor_data (
  id integer NOT NULL PRIMARY KEY,
  instant integer NOT NULL,
  sensor_id int(11) NOT NULL,
  temperature float DEFAULT NULL
);


CREATE TABLE IF NOT EXISTS control_data (
  id integer NOT NULL PRIMARY KEY,
  heating tinyint DEFAULT NULL,
  cooling tinyint DEFAULT NULL
);