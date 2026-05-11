docker run -d \
  --name n8n_db \
  --restart unless-stopped \
  --network withpostgres_default \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=n8n \
  -e MYSQL_USER=mysql \
  -e MYSQL_PASSWORD=mysql \
  -v mysql_data:/var/lib/mysql \
  mysql:8.0