import sys
import time
import hmac
import hashlib
import json
import requests

# Cấu hình thông tin app
APP_ID = "flask-app"
APP_KEY = "my-app-key"
APP_SECRET = "my-app-secret"
BASE_URL = f"http://localhost:4000/apps/{APP_ID}/events"

def generate_rest_signature(app_key, app_secret, method, path, body_dict):
    """
    Tính toán chữ ký HMAC-SHA256 theo đúng chuẩn Pusher REST API:
    String to sign: METHOD\nPATH\nQUERY_STRING (đã sắp xếp)
    """
    timestamp = str(int(time.time()))
    
    # 1. Chuyển body thành chuỗi JSON và tính mã MD5 hex
    body_str = json.dumps(body_dict)
    body_md5 = hashlib.md5(body_str.encode("utf-8")).hexdigest()
    
    # 2. Các tham số xác thực bắt buộc đưa vào query string
    query_params = {
        "auth_key": app_key,
        "auth_timestamp": timestamp,
        "auth_version": "1.0",
        "body_md5": body_md5
    }
    
    # 3. Sắp xếp các query param theo thứ tự alphabet (Key)
    sorted_params = sorted(query_params.items())
    query_string = "&".join([f"{k}={v}" for k, v in sorted_params])
    
    # 4. Xây dựng string_to_sign
    string_to_sign = f"{method.upper()}\n{path}\n{query_string}"
    
    # 5. Ký HMAC-SHA256 bằng app_secret
    signature = hmac.new(
        app_secret.encode("utf-8"),
        string_to_sign.encode("utf-8"),
        hashlib.sha256
    ).hexdigest()
    
    # Thêm chữ ký vào tập tham số gửi đi
    query_params["auth_signature"] = signature
    return query_params, body_str

def trigger_event(channel_name, message_text):
    path = f"/apps/{APP_ID}/events"
    
    payload = {
        "name": "client-message",
        "channels": [channel_name],
        "data": {
            "text": message_text,
            "sender": "Python Secure Sender"
        }
    }
    
    # Tạo chữ ký REST và lấy body dạng chuỗi
    query_params, body_str = generate_rest_signature(
        APP_KEY, APP_SECRET, "POST", path, payload
    )
    
    try:
        # Gửi request kèm theo query parameters chứa chữ ký xác thực
        response = requests.post(BASE_URL, params=query_params, data=body_str, headers={"Content-Type": "application/json"})
        
        if response.status_code == 200:
            print(f"[📤 SUCCESS] Gửi thành công tới kênh '{channel_name}': {message_text}")
        else:
            print(f"[!] Lỗi xác thực hoặc server ({response.status_code}): {response.text}")
    except Exception as e:
        print(f"[!] Không thể kết nối tới Elixir server: {e}")

if __name__ == "__main__":
    channel = "private-chat"
    print(f"[*] Secure Sender Tool đã sẵn sàng cho kênh: {channel}")
    print("[*] Nhập nội dung và nhấn Enter để gửi (Nhấn Ctrl+C để thoát):\n")
    
    try:
        while True:
            text = input(">> ")
            if text.strip():
                trigger_event(channel, text)
    except KeyboardInterrupt:
        print("\n[*] Đã thoát sender tool.")
