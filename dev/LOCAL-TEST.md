# ทดสอบบน Colima ก่อน deploy

ทดสอบทั้งระบบบน Mac เครื่องเดียว: Chrome บน Mac แทน Tesla, HTTP แทน HTTPS, พอร์ต 8088

## 1. เปิด network address ให้ Colima (ต้องทำครั้งเดียว)
Colima ปกติ forward ได้แค่ TCP แต่ WebRTC ต้องใช้ UDP
(container ที่รันอยู่ เช่น acc-nginx จะหยุดชั่วคราวระหว่าง restart)
```bash
colima stop
colima start --network-address
colima list
```
จดค่าในคอลัมน์ `ADDRESS` (เช่น `192.168.64.2`)

## 2. สร้าง `.env` สำหรับทดสอบ
```bash
cd ~/Desktop/DEV/tesla-screenshare
cat > .env <<EOF
DOMAIN=localhost
PUBLISH_TOKEN=$(openssl rand -hex 24)
CONTROL_PIN=123456
COLIMA_IP=$(colima list -j | python3 -c 'import sys,json; print(json.loads(sys.stdin.readline()).get("address",""))')
EOF
cat .env
```
ตรวจว่า `COLIMA_IP` มีค่า ถ้าว่างให้ใส่ IP จากข้อ 1 เอง

## 3. รัน service
```bash
docker compose -f docker-compose.yml -f dev/compose.local.yml up -d --build
docker compose -f docker-compose.yml -f dev/compose.local.yml ps   # tesla-display ต้อง Up
```

## 4. ส่งภาพจาก Mac (Terminal ที่ 1)
```bash
./dev/mac-publish.sh list
set -a; source .env; set +a
SCREEN_URL=http://localhost:8088 TOKEN=$PUBLISH_TOKEN ./dev/mac-publish.sh 1
```
เลือกจอที่ไม่ใช่จอที่จะเปิด Chrome ดู (ไม่งั้นจะเห็นภาพซ้อนไม่สิ้นสุด)
ครั้งแรก macOS จะถามสิทธิ์ Screen Recording ให้ Terminal

## 5. เปิดดูภาพ (แทน Tesla)
เปิด Chrome ไปที่ http://localhost:8088 แล้วกด *View only* ก่อน ต้องเห็นจอที่ส่งมา

## 6. ทดสอบ touch/keyboard (Terminal ที่ 2)
```bash
swiftc -O scripts/mac-input-agent.swift -o mac-input-agent
./mac-input-agent list
set -a; source .env; set +a
SCREEN_URL=http://localhost:8088 TOKEN=$PUBLISH_TOKEN ./mac-input-agent 1
```
ใช้เลขจอเดียวกับข้อ 4 (ครั้งแรกให้สิทธิ์ Accessibility แก่ Terminal แล้วรันใหม่)
รีโหลดหน้า Chrome ใส่ PIN `123456` แล้วลองคลิก/ลาก/พิมพ์ในภาพ เมาส์บนจอนั้นต้องขยับตาม
ใน Chrome ใช้ DevTools > Toggle device toolbar เพื่อจำลองการแตะ (แตะค้าง, สองนิ้ว)

## 7. ดู log / แก้ปัญหา
```bash
docker compose -f docker-compose.yml -f dev/compose.local.yml logs -f
```
- ffmpeg ขึ้น `Connection refused`: `COLIMA_IP` ผิด หรือยังไม่ได้ทำข้อ 1
- หน้าเว็บขึ้น `WHEP 404`: ข้อ 4 ยังไม่ได้รัน
- `input: Mac agent offline`: ข้อ 6 ยังไม่ได้รัน

## 8. ปิดหลังทดสอบเสร็จ
```bash
docker compose -f docker-compose.yml -f dev/compose.local.yml down
rm .env
```
ตอน deploy จริงบน NAS ไม่ต้องใช้ `dev/compose.local.yml` และ `COLIMA_IP`
