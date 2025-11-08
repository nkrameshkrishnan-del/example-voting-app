using System;
using System.Data.Common;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using Newtonsoft.Json;
using Npgsql;
using StackExchange.Redis;

namespace Worker
{
    public class Program
    {
        public static int Main(string[] args)
        {
            try
            {
                // Environment variables for managed services
                var pgHost = Environment.GetEnvironmentVariable("POSTGRES_HOST") ?? "db";
                var pgPort = Environment.GetEnvironmentVariable("POSTGRES_PORT") ?? "5432";
                var pgUser = Environment.GetEnvironmentVariable("POSTGRES_USER") ?? "postgres";
                var pgPassword = Environment.GetEnvironmentVariable("POSTGRES_PASSWORD") ?? "postgres";
                var pgConnString = $"Host={pgHost};Port={pgPort};Username={pgUser};Password={pgPassword};Database=postgres;";

                var redisHost = Environment.GetEnvironmentVariable("REDIS_HOST") ?? "redis";
                var redisPort = Environment.GetEnvironmentVariable("REDIS_PORT") ?? "6379";
                var redisPassword = Environment.GetEnvironmentVariable("REDIS_PASSWORD");
                var redisSsl = (Environment.GetEnvironmentVariable("REDIS_SSL") ?? "false").ToLower() is "1" or "true" or "yes";

                var pgsql = OpenDbConnection(pgConnString);
                var redisConn = OpenRedisConnection(redisHost, redisPort, redisPassword, redisSsl);
                var redis = redisConn.GetDatabase();

                // Keep alive is not implemented in Npgsql yet. This workaround was recommended:
                // https://github.com/npgsql/npgsql/issues/1214#issuecomment-235828359
                var keepAliveCommand = pgsql.CreateCommand();
                keepAliveCommand.CommandText = "SELECT 1";

                var definition = new { vote = "", voter_id = "" };
                while (true)
                {
                    // Slow down to prevent CPU spike, only query each 100ms
                    Thread.Sleep(100);

                    // Reconnect redis if down
                    if (redisConn == null || !redisConn.IsConnected) {
                        Console.WriteLine("Reconnecting Redis");
                        redisConn = OpenRedisConnection(redisHost, redisPort, redisPassword, redisSsl);
                        redis = redisConn.GetDatabase();
                    }
                    string json = redis.ListLeftPopAsync("votes").Result;
                    if (json != null)
                    {
                        var vote = JsonConvert.DeserializeAnonymousType(json, definition);
                        Console.WriteLine($"Processing vote for '{vote.vote}' by '{vote.voter_id}'");
                        // Reconnect DB if down
                        if (!pgsql.State.Equals(System.Data.ConnectionState.Open))
                        {
                            Console.WriteLine("Reconnecting DB");
                            pgsql = OpenDbConnection(pgConnString);
                        }
                        else
                        { // Normal +1 vote requested
                            UpdateVote(pgsql, vote.voter_id, vote.vote);
                        }
                    }
                    else
                    {
                        keepAliveCommand.ExecuteNonQuery();
                    }
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex.ToString());
                return 1;
            }
        }

        private static NpgsqlConnection OpenDbConnection(string connectionString)
        {
            NpgsqlConnection connection;

            while (true)
            {
                try
                {
                    connection = new NpgsqlConnection(connectionString);
                    connection.Open();
                    break;
                }
                catch (SocketException)
                {
                    Console.Error.WriteLine("Waiting for db");
                    Thread.Sleep(1000);
                }
                catch (DbException)
                {
                    Console.Error.WriteLine("Waiting for db");
                    Thread.Sleep(1000);
                }
            }

            Console.Error.WriteLine("Connected to db");

            var command = connection.CreateCommand();
            command.CommandText = @"CREATE TABLE IF NOT EXISTS votes (
                                        id VARCHAR(255) NOT NULL UNIQUE,
                                        vote VARCHAR(255) NOT NULL
                                    )";
            command.ExecuteNonQuery();

            return connection;
        }

        private static ConnectionMultiplexer OpenRedisConnection(string host, string port, string? password, bool ssl)
        {
            var configOptions = new ConfigurationOptions
            {
                EndPoints = { $"{host}:{port}" },
                AbortOnConnectFail = false,
                ConnectRetry = 5,
                ConnectTimeout = 5000,
                SyncTimeout = 5000,
                Ssl = ssl
            };
            if (!string.IsNullOrWhiteSpace(password))
            {
                configOptions.Password = password;
            }

            Console.Error.WriteLine($"Connecting to redis host={host} port={port} ssl={ssl}");
            while (true)
            {
                try
                {
                    return ConnectionMultiplexer.Connect(configOptions);
                }
                catch (RedisConnectionException ex)
                {
                    Console.Error.WriteLine($"Waiting for redis: {ex.Message}");
                    Thread.Sleep(1000);
                }
            }
        }

        // Legacy DNS to IP resolution removed; ElastiCache endpoints resolve directly.

        private static void UpdateVote(NpgsqlConnection connection, string voterId, string vote)
        {
            var command = connection.CreateCommand();
            try
            {
                command.CommandText = "INSERT INTO votes (id, vote) VALUES (@id, @vote)";
                command.Parameters.AddWithValue("@id", voterId);
                command.Parameters.AddWithValue("@vote", vote);
                command.ExecuteNonQuery();
            }
            catch (DbException)
            {
                command.CommandText = "UPDATE votes SET vote = @vote WHERE id = @id";
                command.ExecuteNonQuery();
            }
            finally
            {
                command.Dispose();
            }
        }
    }
}