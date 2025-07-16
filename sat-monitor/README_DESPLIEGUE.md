README - Despliegue en AWS

Este documento describe los pasos necesarios para desplegar la solución de monitoreo de boletines SAT en AWS real.

Prerrequisitos:

1. AWS CLI instalado y configurado con tus credenciales:

   ```bash
   aws configure set region us-east-1
   aws configure set aws_access_key_id YOUR_ACCESS_KEY
   aws configure set aws_secret_access_key YOUR_SECRET_KEY
   ```
2. Terraform (>=1.0) instalado.
3. Python 3.9+ y pip.
4. Archivo `lambda_function.py` y `main.tf` en el mismo directorio del proyecto.

Pasos de despliegue:

1. Empaquetar la función Lambda con dependencias:

   ```bash
   # En la raíz del proyecto
   rm -rf build && mkdir build && cd build
   pip install requests bs4 PyPDF2 -t .
   cp ../lambda_function.py .
   zip -r ../function.zip .
   cd ..
   ```

2. Inicializar Terraform:

   ```bash
   terraform init
   ```

3. Aplicar la infraestructura en AWS:

   ```bash
   terraform apply \
     -var="use_localstack=false" \
     -var='email_password="TU_APP_PASSWORD"' \
     -auto-approve
   ```

   * Esto creará: bucket S3, función Lambda, regla de EventBridge (schedule), IAM roles y políticas, y grupo de logs CloudWatch.

4. Verificar recursos:

   ```bash
   aws lambda list-functions --region us-east-1
   aws s3 ls
   ```

5. Probar la invocación de la Lambda:

   ```bash
   aws lambda invoke \
     --function-name sat-boletines-monitor-monitoreo \
     --region us-east-1 \
     output.json
   cat output.json
   ```

   Debes recibir un JSON con `statusCode` y detalles del análisis.

6. Monitorizar logs en CloudWatch (opcional):

   * En la consola AWS, ve a CloudWatch → Logs → `/aws/lambda/sat-boletines-monitor-monitoreo`.
   * Consulte el log stream más reciente para ver detalles de ejecución y posibles errores.

7. Destruir la infraestructura cuando ya no sea necesaria:

   ```bash
   terraform destroy \
     -var="use_localstack=false" \
     -var='email_password="TU_APP_PASSWORD"' \
     -auto-approve
   ```

   Esto limpiará todos los recursos creados en AWS.

Notas:

* Reemplaza `TU_APP_PASSWORD` por la App Password de Gmail o la contraseña SMTP que uses.
* Asegúrate de que la región configurada en AWS CLI coincida con la definida en Terraform (`us-east-1`).
* Si modificas dependencias o `lambda_function.py`, repite el paso 1 para actualizar `function.zip`.
