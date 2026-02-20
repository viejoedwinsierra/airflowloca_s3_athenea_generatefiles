cd /home/ssm-user
pwd
#instalaar doker 
sudo yum update -y
sudo amazon-linux-extras install -y docker
sudo systemctl enable --now docker
docker --version || sudo docker --version
#installar comp¿se

sudo curl -L "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
docker-compose version

mkdir -p ~/bin ~/airflow-lite
chmod 700 ~/bin

#ir a directorio
cd /home/ssm-user/airflow-lite
