# AzerothCore Portainer Deployment Guide

## 🚀 **Quick Start for Portainer**

This guide will help you deploy AzerothCore in Portainer using your existing NFS storage structure.

### **📁 Files Needed:**
- `portainer-stack.yml` - Main docker-compose stack file
- `portainer-env-template.txt` - Environment variables template
- Your existing `backup-scripts/` directory

---

## **📋 Step 1: Pre-Deployment Setup**

### **1.1 Prepare Storage Directories**
Ensure these directories exist on your NFS storage:
```bash
# Main AzerothCore directory structure
${STORAGE_PATH_CONTAINERS}/azerothcore/
├── mysql/                 # Database files
├── mysql-config/         # MySQL configuration
├── data/                 # Game client data (15GB+)
├── config/               # Server configuration
├── logs/                 # Server logs
├── modules/              # Playerbot modules
├── backups/              # Database backups
├── backup-scripts/       # Backup scripts
├── grafana/              # Grafana data
├── grafana-config/       # Grafana configuration
├── influxdb/             # InfluxDB data
├── cms/                  # CMS data
└── keira3/               # Keira3 data
```

### **1.2 Copy Backup Scripts**
```bash
# Copy your existing backup scripts to NFS storage
cp -r ./backup-scripts/ ${STORAGE_PATH_CONTAINERS}/azerothcore/
```

---

## **📋 Step 2: Portainer Stack Deployment**

### **2.1 Create New Stack in Portainer**
1. Navigate to Portainer → Stacks → Add Stack
2. Name: `azerothcore`
3. Build method: Web editor

### **2.2 Copy Stack Configuration**
Copy the contents of `portainer-stack.yml` into the web editor.

### **2.3 Configure Environment Variables**
In the Environment variables section, add all variables from `portainer-env-template.txt`:

**⚠️ CRITICAL: Update these values for your environment:**
- `STORAGE_PATH_CONTAINERS=/nfs/containers` (your actual NFS path)
- `EXTERNAL_IP=192.168.1.100` (your server's public IP)
- Port numbers (ensure no conflicts with existing services)
- Database passwords
- Web interface credentials

---

## **📋 Step 3: Network Configuration**

### **3.1 Port Mappings**
The stack uses these external ports (configurable):
- **3784**: Authentication server
- **8215**: World server
- **64306**: MySQL database
- **7778**: SOAP interface (if enabled)
- **8081**: PHPMyAdmin
- **3001**: Grafana
- **8087**: InfluxDB
- **4201**: Keira3 database editor
- **8001**: CMS web interface

### **3.2 Firewall Rules**
Ensure your firewall allows:
- Ports 3784 and 8215 for game clients
- Web interface ports for management access

---

## **📋 Step 4: Deployment Process**

### **4.1 Initial Deployment**
1. Click "Deploy the stack"
2. Monitor the deployment in Portainer logs
3. Services will start in this order:
   - MySQL database
   - Database initialization
   - Authentication server
   - Client data download (15GB - may take 30+ minutes)
   - World server
   - Web interfaces

### **4.2 Monitor Progress**
Watch these services for successful startup:
- `ac-mysql`: Database ready
- `ac-client-data`: Game data download complete
- `ac-authserver`: Authentication ready
- `ac-worldserver`: World server operational

---

## **📋 Step 5: Post-Deployment Verification**

### **5.1 Service Health Checks**
All services include health checks. In Portainer, verify:
- ✅ All containers showing "healthy" status
- ✅ No containers in "restarting" state

### **5.2 Web Interface Access**
Test access to management interfaces:
- **PHPMyAdmin**: `http://your-server:8081`
- **Grafana**: `http://your-server:3001` (admin/acore123)
- **Keira3**: `http://your-server:4201`
- **CMS**: `http://your-server:8001`

### **5.3 Game Server Testing**
1. Check worldserver logs for "AzerothCore ready" message
2. Test client connection to your server IP on port 3784
3. Verify realm list shows your server

---

## **🔧 Maintenance & Operations**

### **Backup Management**
- Automated backups run at 3 AM daily (configurable)
- Backups stored in `${STORAGE_PATH_CONTAINERS}/azerothcore/backups/`
- Retention: 7 days (configurable)

### **Log Access**
- Server logs: `${STORAGE_PATH_CONTAINERS}/azerothcore/logs/`
- Container logs: Available in Portainer → Container → Logs

### **Configuration Updates**
- Server config: `${STORAGE_PATH_CONTAINERS}/azerothcore/config/`
- Restart containers after config changes

---

## **🚨 Troubleshooting**

### **Common Issues:**

**1. Client Data Download Fails**
- Check internet connectivity
- Verify storage permissions
- Monitor `ac-client-data` container logs

**2. Database Connection Errors**
- Verify MySQL container is healthy
- Check database credentials
- Ensure network connectivity between containers

**3. Port Conflicts**
- Update port mappings in environment variables
- Restart stack after port changes

**4. Storage Permission Issues**
- Verify NFS mount permissions
- Check container user permissions
- Ensure storage paths exist

### **Log Locations:**
- Portainer: Container logs in web interface
- Server logs: `${STORAGE_PATH_CONTAINERS}/azerothcore/logs/`
- Database logs: MySQL container logs in Portainer

---

## **📈 Monitoring & Metrics**

The stack includes comprehensive monitoring:

- **Grafana Dashboard**: Real-time server metrics
- **InfluxDB**: Metrics storage
- **Built-in Health Checks**: Automatic container monitoring
- **Backup Status**: Automated backup verification

Access monitoring at: `http://your-server:3001`

---

## **🔐 Security Notes**

- Change default passwords before deployment
- Restrict web interface access to management networks
- Use strong database passwords
- Regular security updates for containers
- Monitor access logs

---

**✅ Your AzerothCore server is now ready for production use in Portainer!**