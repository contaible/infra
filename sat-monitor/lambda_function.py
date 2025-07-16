import requests
from bs4 import BeautifulSoup
import PyPDF2
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
import boto3
from datetime import datetime
import os
import logging
from typing import List, Dict, Optional
from urllib.parse import urljoin, urlparse
import time
from botocore.exceptions import ClientError, NoCredentialsError
import tempfile
import hashlib

# Configuración de logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuración
SAT_URL = "http://omawww.sat.gob.mx/sala_prensa/boletin_tecnico/Paginas/default.aspx"
KEYWORDS = ["CFDI 4.0", "Anexo 20", "contabilidad electrónica", "e.firma"]
S3_BUCKET = os.environ.get("S3_BUCKET")
EMAIL_SENDER = os.environ.get("EMAIL_SENDER")
EMAIL_RECIPIENT = os.environ.get("EMAIL_RECIPIENT")
EMAIL_PASSWORD = os.environ.get("EMAIL_PASSWORD")
EMAIL_SUBJECT = "Actualización en Boletines Técnicos del SAT"

# Configuración de timeouts y reintentos
REQUEST_TIMEOUT = 30
MAX_RETRIES = 3
RETRY_DELAY = 2


class SATMonitorError(Exception):
    """Excepción personalizada para errores del monitor SAT"""
    pass


def validate_environment():
    """Valida que todas las variables de entorno requeridas estén configuradas"""
    required_vars = ["S3_BUCKET", "EMAIL_SENDER", "EMAIL_RECIPIENT", "EMAIL_PASSWORD"]
    missing_vars = [var for var in required_vars if not os.environ.get(var)]
    
    if missing_vars:
        raise SATMonitorError(f"Variables de entorno faltantes: {', '.join(missing_vars)}")


def get_with_retries(url: str, max_retries: int = MAX_RETRIES) -> requests.Response:
    """Realiza una petición HTTP con reintentos automáticos"""
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    }
    
    for attempt in range(max_retries):
        try:
            logger.info(f"Intentando descargar: {url} (intento {attempt + 1}/{max_retries})")
            response = requests.get(url, timeout=REQUEST_TIMEOUT, headers=headers)
            response.raise_for_status()
            return response
        except requests.exceptions.RequestException as e:
            if attempt == max_retries - 1:
                raise SATMonitorError(f"Error al descargar {url} después de {max_retries} intentos: {e}")
            logger.warning(f"Error en intento {attempt + 1}: {e}. Reintentando en {RETRY_DELAY} segundos...")
            time.sleep(RETRY_DELAY)


def scrape_boletines() -> List[str]:
    """Extrae enlaces a PDFs de boletines técnicos del SAT"""
    try:
        response = get_with_retries(SAT_URL)
        soup = BeautifulSoup(response.text, "html.parser")
        
        pdf_links = []
        for link in soup.find_all("a", href=True):
            href = link["href"]
            if href.endswith(".pdf"):
                # Construir URL absoluta usando urljoin
                pdf_url = urljoin(SAT_URL, href)
                pdf_links.append(pdf_url)
        
        logger.info(f"Se encontraron {len(pdf_links)} enlaces a PDFs")
        return pdf_links
        
    except Exception as e:
        raise SATMonitorError(f"Error al extraer boletines: {e}")


def extract_text_from_pdf(pdf_path: str) -> str:
    """Extrae texto de un archivo PDF con manejo de errores mejorado"""
    try:
        with open(pdf_path, 'rb') as file:
            reader = PyPDF2.PdfReader(file)
            text_parts = []
            
            for page_num, page in enumerate(reader.pages):
                try:
                    page_text = page.extract_text()
                    if page_text:
                        text_parts.append(page_text)
                except Exception as e:
                    logger.warning(f"Error al extraer texto de la página {page_num}: {e}")
                    continue
            
            return " ".join(text_parts)
            
    except Exception as e:
        logger.error(f"Error al procesar PDF {pdf_path}: {e}")
        return ""


def file_already_processed(s3_client, pdf_url: str) -> bool:
    """Verifica si un archivo ya fue procesado usando hash del contenido"""
    try:
        # Crear hash único basado en la URL
        url_hash = hashlib.md5(pdf_url.encode()).hexdigest()
        key = f"processed/{url_hash}.txt"
        
        s3_client.head_object(Bucket=S3_BUCKET, Key=key)
        return True
    except ClientError as e:
        if e.response['Error']['Code'] == '404':
            return False
        raise


def mark_as_processed(s3_client, pdf_url: str):
    """Marca un archivo como procesado"""
    try:
        url_hash = hashlib.md5(pdf_url.encode()).hexdigest()
        key = f"processed/{url_hash}.txt"
        
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=key,
            Body=f"Procesado: {datetime.now().isoformat()}\nURL: {pdf_url}"
        )
    except Exception as e:
        logger.warning(f"Error al marcar archivo como procesado: {e}")


def analyze_pdfs(pdf_links: List[str]) -> List[Dict]:
    """Analiza PDFs en busca de palabras clave con manejo mejorado"""
    updates = []
    s3_client = boto3.client("s3")
    
    # Limitar a los primeros 10 PDFs para evitar timeouts
    for pdf_url in pdf_links[:10]:
        try:
            # Verificar si ya fue procesado
            if file_already_processed(s3_client, pdf_url):
                logger.info(f"Archivo ya procesado: {pdf_url}")
                continue
                
            # Descargar PDF
            pdf_response = get_with_retries(pdf_url)
            pdf_name = os.path.basename(urlparse(pdf_url).path) or "documento.pdf"
            
            # Usar tempfile para manejo seguro de archivos temporales
            with tempfile.NamedTemporaryFile(delete=False, suffix='.pdf') as tmp_file:
                tmp_file.write(pdf_response.content)
                tmp_path = tmp_file.name
            
            try:
                # Extraer texto
                text = extract_text_from_pdf(tmp_path)
                
                if not text:
                    logger.warning(f"No se pudo extraer texto de {pdf_name}")
                    continue
                
                # Buscar palabras clave
                found_keywords = []
                for keyword in KEYWORDS:
                    if keyword.lower() in text.lower():
                        found_keywords.append(keyword)
                
                if found_keywords:
                    updates.append({
                        "pdf": pdf_name,
                        "keywords": found_keywords,
                        "url": pdf_url,
                        "processed_at": datetime.now().isoformat()
                    })
                    logger.info(f"Palabras clave encontradas en {pdf_name}: {found_keywords}")
                
                # Subir a S3
                s3_key = f"boletines/{datetime.now():%Y%m%d}/{pdf_name}"
                s3_client.upload_file(tmp_path, S3_BUCKET, s3_key)
                
                # Marcar como procesado
                mark_as_processed(s3_client, pdf_url)
                
            finally:
                # Limpiar archivo temporal
                if os.path.exists(tmp_path):
                    os.unlink(tmp_path)
                    
        except Exception as e:
            logger.error(f"Error al procesar {pdf_url}: {e}")
            continue
    
    return updates


def send_email(updates: List[Dict]):
    """Envía email con actualizaciones encontradas"""
    if not updates:
        logger.info("No hay actualizaciones para enviar")
        return
    
    try:
        # Crear mensaje con formato HTML
        msg = MIMEMultipart('alternative')
        msg["Subject"] = EMAIL_SUBJECT
        msg["From"] = EMAIL_SENDER
        msg["To"] = EMAIL_RECIPIENT
        
        # Crear contenido en texto plano
        text_body = "Se encontraron actualizaciones en los boletines técnicos del SAT:\n\n"
        for update in updates:
            text_body += f"- {update['pdf']}: {', '.join(update['keywords'])}\n"
            text_body += f"  URL: {update['url']}\n"
            text_body += f"  Procesado: {update['processed_at']}\n\n"
        
        # Crear contenido en HTML
        html_body = """
        <html>
        <body>
            <h2>Actualizaciones en Boletines Técnicos del SAT</h2>
            <p>Se encontraron las siguientes actualizaciones:</p>
            <ul>
        """
        
        for update in updates:
            html_body += f"""
                <li>
                    <strong>{update['pdf']}</strong><br>
                    Palabras clave: {', '.join(update['keywords'])}<br>
                    <a href="{update['url']}">Ver documento</a><br>
                    Procesado: {update['processed_at']}
                </li>
            """
        
        html_body += """
            </ul>
        </body>
        </html>
        """
        
        # Adjuntar ambos formatos
        msg.attach(MIMEText(text_body, 'plain'))
        msg.attach(MIMEText(html_body, 'html'))
        
        # Enviar email
        with smtplib.SMTP("smtp.gmail.com", 587) as server:
            server.starttls()
            server.login(EMAIL_SENDER, EMAIL_PASSWORD)
            server.sendmail(EMAIL_SENDER, EMAIL_RECIPIENT, msg.as_string())
        
        logger.info(f"Email enviado con {len(updates)} actualizaciones")
        
    except Exception as e:
        raise SATMonitorError(f"Error al enviar email: {e}")


def save_log(s3_client, log_message: str, log_type: str = "info"):
    """Guarda logs en S3 con manejo de errores"""
    try:
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        key = f"logs/{log_type}_{timestamp}.txt"
        
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=key,
            Body=log_message,
            ContentType="text/plain"
        )
        
    except Exception as e:
        logger.error(f"Error al guardar log en S3: {e}")


def lambda_handler(event, context):
    """Función principal de Lambda con manejo de errores mejorado"""
    start_time = datetime.now()
    
    try:
        # Validar configuración
        validate_environment()
        
        # Inicializar cliente S3
        s3_client = boto3.client("s3")
        
        # Ejecutar monitoreo
        logger.info("Iniciando monitoreo de boletines SAT")
        
        pdf_links = scrape_boletines()
        updates = analyze_pdfs(pdf_links)
        send_email(updates)
        
        # Crear log de éxito
        execution_time = (datetime.now() - start_time).total_seconds()
        log_message = (
            f"Monitoreo ejecutado exitosamente: {datetime.now().isoformat()}\n"
            f"Tiempo de ejecución: {execution_time:.2f} segundos\n"
            f"PDFs encontrados: {len(pdf_links)}\n"
            f"Actualizaciones detectadas: {len(updates)}\n"
            f"Actualizaciones: {[u['pdf'] for u in updates]}"
        )
        
        save_log(s3_client, log_message, "success")
        logger.info(log_message)
        
        return {
            "statusCode": 200,
            "body": {
                "status": "success",
                "updates_found": len(updates),
                "pdfs_analyzed": len(pdf_links),
                "execution_time": execution_time
            }
        }
        
    except SATMonitorError as e:
        logger.error(f"Error en monitoreo SAT: {e}")
        error_log = f"Error en monitoreo SAT: {e}\nTimestamp: {datetime.now().isoformat()}"
        
        try:
            s3_client = boto3.client("s3")
            save_log(s3_client, error_log, "error")
        except:
            pass
        
        return {
            "statusCode": 500,
            "body": {"status": "error", "message": str(e)}
        }
        
    except Exception as e:
        logger.error(f"Error inesperado: {e}")
        error_log = f"Error inesperado: {e}\nTimestamp: {datetime.now().isoformat()}"
        
        try:
            s3_client = boto3.client("s3")
            save_log(s3_client, error_log, "error")
        except:
            pass
        
        return {
            "statusCode": 500,
            "body": {"status": "error", "message": "Error interno del servidor"}
        }


if __name__ == "__main__":
    # Para testing local
    result = lambda_handler({}, {})
    print(f"Resultado: {result}")