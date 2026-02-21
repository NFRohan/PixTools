"""DnCNN (Denoising Convolutional Neural Network) PyTorch model definition."""

import torch.nn as nn


class DnCNN(nn.Module):
    def __init__(self, channels=3, num_layers=20, features=64):
        super().__init__()
        layers = []

        # Exact structure from checkpoint: 19 Conv+ReLU layers, 1 Conv layer. All bias=True, no BatchNorm.
        for i in range(num_layers - 1):
            c_in = channels if i == 0 else features
            layers.append(nn.Conv2d(in_channels=c_in, out_channels=features, kernel_size=3, padding=1, bias=True))
            layers.append(nn.ReLU(inplace=True))

        # Last layer
        layers.append(nn.Conv2d(in_channels=features, out_channels=channels, kernel_size=3, padding=1, bias=True))

        self.model = nn.Sequential(*layers)

    def forward(self, x):
        noise = self.model(x)
        return x - noise
