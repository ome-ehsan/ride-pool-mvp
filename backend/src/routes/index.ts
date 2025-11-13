import { Router } from 'express';
import userRoutes from './user.routes';
import poolRoutes from './pool.routes';
import rideRoutes from './ride.routes';
import paymentRoutes from './payment.routes';

const router = Router();

router.use('/users', userRoutes);
router.use('/pools', poolRoutes);
router.use('/rides', rideRoutes);
router.use('/payments', paymentRoutes);

export default router;