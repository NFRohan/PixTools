"""DnCNN (Denoising Convolutional Neural Network) PyTorch model definition."""

import torch.nn as nn

class DnCNN(nn.Module):
    def __init__(self, channels=3, num_layers=20, features=64):
        super(DnCNN, self).__init__()
        layers = []
        
        # Layer 1: Conv + ReLU
        layers.append(nn.Conv2d(in_channels=channels, out_channels=features, kernel_size=3, padding=1, bias=False))
        layers.append(nn.ReLU(inplace=True))
        
        # Layers 2 to num_layers-1: Conv + BatchNorm + ReLU
        for _ in range(num_layers - 2):
            layers.append(nn.Conv2d(in_channels=features, out_channels=features, kernel_size=3, padding=1, bias=False))
            layers.append(nn.BatchNorm2d(features))
            layers.append(nn.ReLU(inplace=True))
            
        # Last Layer: Conv
        layers.append(nn.Conv2d(in_channels=features, out_channels=channels, kernel_size=3, padding=1, bias=False))
        
        self.dncnn = nn.Sequential(*layers)

    def forward(self, x):
        # DnCNN predicts the noise residual, so we subtract it from the input
        noise = self.dncnn(x)
        return x - noise
