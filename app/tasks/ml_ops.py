"""DnCNN Machine Learning tasks."""

import logging
import numpy as np
import torch
from PIL import Image
from celery.signals import worker_init

from app.ml.dncnn import DnCNN
from app.services.s3 import download_raw, upload_processed
from app.tasks.celery_app import celery_app

logger = logging.getLogger(__name__)

_model = None

@worker_init.connect
def load_model(**kwargs):
    """Load the model once at worker startup."""
    global _model
    logger.info("Loading DnCNN model into memory...")
    
    # Restrict PyTorch CPU threads to prevent OOM on Docker host
    torch.set_num_threads(1)
    
    _model = DnCNN()
    # Ensure map_location="cpu" since workers are cpu-only
    _model.load_state_dict(torch.load("models/dncnn_color_blind.pth", map_location="cpu"))
    _model.eval()
    logger.info("DnCNN model loaded and ready.")


@celery_app.task(name="app.tasks.ml_ops.denoise", bind=True, max_retries=3)
def denoise(self, job_id: str, s3_raw_key: str) -> str:
    """Run DnCNN inference to denoise an S3-hosted image."""
    global _model
    if _model is None:
        logger.error("Model not loaded!")
        raise RuntimeError("Model not initialized.")

    try:
        logger.info("Job %s: starting DnCNN denoising", job_id)
        
        # 1. Download image
        image = download_raw(s3_raw_key).convert("RGB")
        
        # 2. Preprocess: PIL Image -> numpy [H, W, 3] -> tensor [1, 3, H, W] in [0, 1]
        img_np = np.array(image, dtype=np.float32) / 255.0
        # HWC to CHW
        img_np = np.transpose(img_np, (2, 0, 1))
        # Add batch dimension
        tensor_in = torch.from_numpy(img_np).unsqueeze(0)

        # 3. Inference
        with torch.inference_mode():
            tensor_out = _model(tensor_in)
            
        # 4. Postprocess: tensor [1, 3, H, W] -> numpy [H, W, 3] -> [0, 255] uint8 -> PIL Image
        # clamp to [0, 1]
        tensor_out = torch.clamp(tensor_out, 0.0, 1.0)
        out_np = tensor_out.squeeze(0).cpu().numpy()
        # CHW to HWC
        out_np = np.transpose(out_np, (1, 2, 0))
        out_img_np = (out_np * 255.0).round().astype(np.uint8)
        
        out_image = Image.fromarray(out_img_np)
        
        # 5. Upload to S3
        # Denoised image benefits from lossless format to prevent reintroducing JPEG compression noise
        s3_key = upload_processed(out_image, job_id, "denoise", "PNG")
        
        logger.info("Job %s: denoising complete → %s", job_id, s3_key)
        return s3_key

    except Exception as exc:
        raise self.retry(exc=exc)
