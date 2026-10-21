import hmac
import hashlib
from flask import Flask, request, jsonify
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

# Cấu hình App credentials (phải khớp với dữ liệu đã seed trong Elixir AppStore)
APP_KEY = "my-app-key"
APP_SECRET = "my-app-secret"

@app.route("/pusher/auth", methods=["POST"])
def pusher_auth():
    data = request.json
    socket_id = data.get("socket_id")
    channel_name = data.get("channel_name")

    if not socket_id or not channel_name:
        return jsonify({"error": "Missing socket_id or channel_name"}), 400

    # Chỉ cho phép authenticate các kênh bắt đầu bằng private-
    if not channel_name.startswith("private-"):
        return jsonify({"error": "Unauthorized channel type"}), 403

    # Xây dựng chuỗi cần ký theo chuẩn Pusher Protocol: "<socket_id>:<channel_name>"
    string_to_sign = f"{socket_id}:{channel_name}"

    # Tính HMAC-SHA256
    signature = hmac.new(
        APP_SECRET.encode("utf-8"),
        string_to_sign.encode("utf-8"),
        hashlib.sha256
    ).hexdigest()

    # Định dạng trả về cho client theo chuẩn Pusher: "app_key:signature"
    auth_token = f"{APP_KEY}:{signature}"

    return jsonify({"auth": auth_token})

if __name__ == "__main__":
    # Chạy flask server ở cổng 5000
    app.run(port=5000, debug=True)
