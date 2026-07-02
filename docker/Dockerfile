FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY manifest.yaml .
COPY .streamlit ./.streamlit

EXPOSE 6006

CMD ["sh", "-c", "streamlit run app/streamlit_app.py --server.address=0.0.0.0 --server.port=6006 --server.headless=true --browser.gatherUsageStats=false"]
