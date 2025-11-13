import { Router } from 'express';
import { authenticate } from '../middleware/auth';

const router = Router();

router.post('/process', authenticate, async (req, res, next) => {
  try {
    res.json({ message: 'Process payment endpoint' });
  } catch (error) {
    next(error);
  }
});

router.get('/history', authenticate, async (req, res, next) => {
  try {
    res.json({ message: 'Payment history endpoint' });
  } catch (error) {
    next(error);
  }
});

export default router;