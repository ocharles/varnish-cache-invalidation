# Varnish Cache Invalidation Via PostgreSQL and RabbitMQ

This project contains my prototype for doing Varnish cache invalidation with
RabbitMQ and pg_amqp.

## Installation

You will need:

* A PostgreSQL database, >= 9.2
* RabbitMQ
* [pg_amqp](https://github.com/omniti-labs/pg_amqp)
* Haskell dependencies:
  * resourcet, aeson, bytestring, text, postgresql-simple, amqp, http-conduit, hslogger
* Varnish

## Usage

1. Install pg_amqp from source
2. Run `CREATE EXTENSION amqp` in your database
3. Add a broker with: `INSERT INTO amqp.broker (host, username, password) VALUES ('localhost', 'guest', 'guest')'. Change parameters to suit your installation of RabbitMQ.
4. Install RabbitMQ event triggers. As a user with access to the `amqp` schema (ie, `postgres'), run the following:
    ```
    CREATE OR REPLACE FUNCTION rabbitmq()
    RETURNS TRIGGER AS $$
      BEGIN
        IF TG_OP = 'INSERT' THEN
          PERFORM amqp.publish(1, 'pg', 'database', row_to_json(e)::text)
            FROM (VALUES ('artist', lower(TG_OP), NEW))
              AS e ("table", event, "new");
        ELSIF TG_OP = 'DELETE' THEN
          PERFORM amqp.publish(1, 'pg', 'database', row_to_json(e)::text)
            FROM (VALUES ('artist', lower(TG_OP), OLD))
              AS e ("table", event, "old");
        ELSIF TG_OP = 'UPDATE' THEN
          PERFORM amqp.publish(1, 'pg', 'database', row_to_json(e)::text)
            FROM (VALUES ('artist', lower(TG_OP), OLD, NEW))
              AS e ("table", event, "old", "new");
        END IF;
        RETURN NULL;
      END;
    $$ LANGUAGE 'plpgsql' VOLATILE
    SECURITY DEFINER;

    CREATE OR REPLACE FUNCTION install_rabbitmq(table_name regclass)
    RETURNS void AS $$
      BEGIN
        EXECUTE
          'CREATE TRIGGER rabbitmq AFTER INSERT OR DELETE OR UPDATE ' ||
          'ON ' || table_name || ' FOR EACH ROW EXECUTE PROCEDURE rabbitmq()';
      END;
    $$ LANGUAGE 'plpgsql' VOLATILE;

    CREATE OR REPLACE FUNCTION uninstall_rabbitmq(table_name regclass)
    RETURNS void AS $$
      BEGIN
        EXECUTE
          'DROP TRIGGER rabbitmq ON ' || table_name;
      END;
    $$ LANGUAGE 'plpgsql' VOLATILE;
    ```
5. Install some triggers with `SELECT install_rabbitmq('artist')`. Paramater is any table name.
6. Run the daemon with `runghc amqp.hs`
7. Setup Varnish to use the varnish.acl file in this repository.
8. Run `musicbrainz-server` on port 5000, and Varnish on port 9000.
9. Change some rows in your PostgreSQL database and notice what happens
