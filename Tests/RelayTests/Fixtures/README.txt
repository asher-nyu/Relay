Fictional synthesized speech for Relay's opt-in integration tests.

English.aiff: macOS Samantha voice, 160 words per minute.
Welcome to Relay. This is a fictional recording used to check local language detection. The planning meeting starts at nine tomorrow morning. Please bring the new project notes and the latest design.

Spanish.aiff: macOS Mónica voice, 145 words per minute.
Hola, buenos días. Esta es una prueba de reconocimiento de voz en español. Mañana tendremos una reunión para hablar sobre el proyecto y revisar las notas del equipo. Queremos saber qué idioma se está hablando en este momento.

These fixtures contain no user conversations or personal data. The tests never open a microphone or a system-audio capture stream. Set RELAY_AUDIO_INTEGRATION=1 to opt in; speech models may download on first use.
