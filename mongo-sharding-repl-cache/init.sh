#!/bin/bash

docker compose exec -T configSrv mongosh --port 27017 <<EOF
rs.initiate(
  {
    _id : "configSrv",
    configsvr: true,
    members: [
      { _id : 0, host : "configSrv:27017" }
    ]
  }
);
exit();
EOF

docker compose exec -T shard1-repl1 mongosh --port 27020 <<EOF
rs.initiate(
    {
      _id : "shard1",
      members: [
        { _id : 0, host : "shard1-repl1:27020" },
        { _id : 1, host : "shard1-repl2:27020" },
        { _id : 2, host : "shard1-repl3:27020" }
      ]
    }
);
exit();
EOF

docker compose exec -T shard2-repl1 mongosh --port 27020 <<EOF
rs.initiate(
    {
      _id : "shard2",
      members: [
        { _id : 0, host : "shard2-repl1:27020" },
        { _id : 1, host : "shard2-repl2:27020" },
        { _id : 2, host : "shard2-repl3:27020" }
      ]
    }
  );
exit();
EOF

docker compose exec -T mongos_router mongosh --port 27018 <<EOF
sh.addShard( "shard1/shard1-repl1:27020,shard1-repl2:27020,shard1-repl3:27020");
sh.addShard( "shard2/shard2-repl1:27020,shard2-repl2:27020,shard2-repl2:27020");

sh.enableSharding("somedb");
sh.shardCollection("somedb.helloDoc", { "name" : "hashed" } )

use somedb
for(var i = 0; i < 1000; i++) db.helloDoc.insert({age:i, name:"ly"+i})

exit();
EOF